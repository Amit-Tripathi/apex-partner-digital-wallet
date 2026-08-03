/**
 * DigitalWalletConsumptionService
 *
 * Reproduces the per-card numbers shown on the Digital Wallet cards UI:
 *   Total Credits, Credits Consumed, Remaining, % Consumed, % Remaining.
 *
 * Data source: Data 360 (Data Cloud) Data Model Objects (DMOs):
 *   - TenantEntitlementTransaction__dlm    (entitlements / Total Credits)
 *   - TenantDailyEntitlementConsumption__dlm (daily consumption)
 *
 * Design notes:
 *   - Consumption is AGGREGATED AT THE SOURCE (Data 360), not pulled row-by-row.
 *     Fetching every daily row for a card's term exceeds the DMO direct-assignment
 *     row cap in production (a QueryException: "Inline query has too many rows for
 *     direct assignment"). Instead:
 *       * SUM cards -> a single SUM(unitsconsumed__c) aggregate per card/window.
 *       * MAX cards -> the latest Production snapshot (ORDER BY date DESC LIMIT 1).
 *       * Aggregation type is detected per card with a LIMIT 1 typed probe.
 *   - The entitlements query stays a small typed direct-assignment query.
 *   - DMO SOQL can only be mocked with typed rows via SoqlStubProvider; aggregate
 *     (AggregateResult) queries can't be mocked. So the one aggregate call
 *     (sumConsumedForCard) is fronted by a @TestVisible seam (sumConsumedOverride),
 *     and the classification / snapshot / aggregation type probes use typed queries
 *     that tests mock directly. Pure result-shaping lives in buildResults().
 *   - Ecosystem-safe: no hardcoded card names or dates. Each card's own active term
 *     window [StartDate, EndDate) is derived from its entitlements, and consumption
 *     is only counted inside that window.
 */
public with sharing class DigitalWalletConsumptionService {

    // Entitlements at/above this quantity are provisioned as effectively "unlimited".
    @TestVisible
    static final Decimal UNLIMITED_THRESHOLD = 1000000000000L;

    // ---- Test seams ----
    // Aggregate (AggregateResult) SOQL against DMOs can't be mocked with
    // SoqlStubProvider, so tests inject the SUM result and/or the per-card
    // aggregation type / consumed values through these overrides.
    @TestVisible
    static Map<String, Decimal> sumConsumedOverride;
    @TestVisible
    static Map<String, String> aggTypeOverride;
    @TestVisible
    static Map<String, Decimal> consumedOverride;

    /** Computed metrics for a single wallet card. */
    public class CardConsumption implements Comparable {
        public String   card;
        public String   aggType;
        public Datetime termStart;
        public Datetime termEnd;
        public Decimal  totalCredits;
        public Decimal  consumed;
        public Decimal  remaining;
        public Decimal  pctConsumed;
        public Decimal  pctRemaining;
        public String   note;

        public Integer compareTo(Object o) {
            CardConsumption other = (CardConsumption) o;
            String a = (card == null) ? '' : card;
            String b = (other.card == null) ? '' : other.card;
            return a.compareTo(b);
        }
    }

    /**
     * Computes per-card consumption for every card with an active entitlement.
     * @return list of CardConsumption, sorted by card developer name.
     */
    public static List<CardConsumption> computeConsumption() {
        // ---- Step 1: active entitlements -> Total Credits + per-card term window ----
        Map<String, Decimal>  totalByCard     = new Map<String, Decimal>();
        Map<String, Datetime> termStartByCard = new Map<String, Datetime>();
        Map<String, Datetime> termEndByCard   = new Map<String, Datetime>();

        // Entitlements are few (one row per transaction), so a direct-assignment
        // typed query is safe here and remains mockable via SoqlStubProvider.
        List<TenantEntitlementTransaction__dlm> ents = [
            SELECT entitlementcarddefdevlname__c, quantity__c, startdate__c, enddate__c
            FROM TenantEntitlementTransaction__dlm
            WHERE entitlementtransactiontype__c IN ('Add', 'Reduction')
              AND (entitlementtransactionsubtype__c != 'Reparenting'
                   OR entitlementtransactionsubtype__c = null)
              AND startdate__c <= TODAY
              AND enddate__c > TODAY
        ];
        for (TenantEntitlementTransaction__dlm e : ents) {
            String card = e.entitlementcarddefdevlname__c;
            if (card == null) {
                continue;
            }
            Decimal q = (e.quantity__c == null) ? 0 : e.quantity__c;
            Decimal running = totalByCard.containsKey(card) ? totalByCard.get(card) : 0;
            totalByCard.put(card, running + q);

            if (e.startdate__c != null &&
                (!termStartByCard.containsKey(card) || e.startdate__c < termStartByCard.get(card))) {
                termStartByCard.put(card, e.startdate__c);
            }
            if (e.enddate__c != null &&
                (!termEndByCard.containsKey(card) || e.enddate__c > termEndByCard.get(card))) {
                termEndByCard.put(card, e.enddate__c);
            }
        }

        if (totalByCard.isEmpty()) {
            return new List<CardConsumption>();
        }

        // ---- Step 2: per-card aggregation type + consumed (aggregated at source) ----
        Map<String, String>  aggTypeByCard  = new Map<String, String>();
        Map<String, Decimal> consumedByCard = new Map<String, Decimal>();
        for (String card : totalByCard.keySet()) {
            Datetime tStart = termStartByCard.get(card);
            Datetime tEnd   = termEndByCard.get(card);
            String aggType  = aggTypeForCard(card);
            aggTypeByCard.put(card, aggType);
            consumedByCard.put(card, consumedForCard(card, aggType, tStart, tEnd));
        }

        // ---- Step 3: shape the per-card results ----
        return buildResults(totalByCard, termStartByCard, termEndByCard, aggTypeByCard, consumedByCard);
    }

    /**
     * Classifies a card as MAX (point-in-time snapshot) or SUM (drawdown). A card
     * is provisioned as one type, so a single MAX probe row is enough to classify.
     * Typed query -> mockable via SoqlStubProvider.
     */
    @TestVisible
    static String aggTypeForCard(String card) {
        if (aggTypeOverride != null && aggTypeOverride.containsKey(card)) {
            return aggTypeOverride.get(card);
        }
        List<TenantDailyEntitlementConsumption__dlm> maxProbe = [
            SELECT usageaggregationtype__c
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c = :card
              AND usageaggregationtype__c = 'MAX'
            LIMIT 1
        ];
        return maxProbe.isEmpty() ? 'SUM' : 'MAX';
    }

    /** Dispatches to the SUM or MAX consumption strategy for a card. */
    @TestVisible
    static Decimal consumedForCard(String card, String aggType, Datetime tStart, Datetime tEnd) {
        if (consumedOverride != null && consumedOverride.containsKey(card)) {
            return consumedOverride.get(card);
        }
        return (aggType == 'MAX')
            ? maxSnapshotForCard(card, tStart, tEnd)
            : sumConsumedForCard(card, tStart, tEnd);
    }

    /**
     * Cumulative drawdown: SUM(unitsconsumed__c) within the term, aggregated at the
     * source so the full daily row set is never materialized. The aggregate result
     * can't be mocked, so tests inject the value via sumConsumedOverride.
     */
    @TestVisible
    static Decimal sumConsumedForCard(String card, Datetime tStart, Datetime tEnd) {
        if (sumConsumedOverride != null && sumConsumedOverride.containsKey(card)) {
            return sumConsumedOverride.get(card);
        }
        AggregateResult[] rs = [
            SELECT SUM(unitsconsumed__c) consumed
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c = :card
              AND utilizationdate__c >= :tStart
              AND utilizationdate__c <  :tEnd
        ];
        Object v = rs.isEmpty() ? null : rs[0].get('consumed');
        return (v == null) ? 0 : Decimal.valueOf(String.valueOf(v));
    }

    /**
     * Point-in-time allocation: the latest Production snapshot within the term,
     * falling back to the latest reading in any environment. Both are single-row
     * typed queries -> mockable via SoqlStubProvider.
     */
    @TestVisible
    static Decimal maxSnapshotForCard(String card, Datetime tStart, Datetime tEnd) {
        List<TenantDailyEntitlementConsumption__dlm> snap = [
            SELECT unitsconsumed__c
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c = :card
              AND Usage_Business_Environment_Type__c = 'Production'
              AND utilizationdate__c >= :tStart
              AND utilizationdate__c <  :tEnd
            ORDER BY utilizationdate__c DESC
            LIMIT 1
        ];
        if (snap.isEmpty()) {
            snap = [
                SELECT unitsconsumed__c
                FROM TenantDailyEntitlementConsumption__dlm
                WHERE carddefinitiondevelopername__c = :card
                  AND utilizationdate__c >= :tStart
                  AND utilizationdate__c <  :tEnd
                ORDER BY utilizationdate__c DESC
                LIMIT 1
            ];
        }
        return (snap.isEmpty() || snap[0].unitsconsumed__c == null)
            ? 0 : Decimal.valueOf(String.valueOf(snap[0].unitsconsumed__c));
    }

    /** Shapes the per-card maps into sorted CardConsumption results. Pure logic. */
    @TestVisible
    static List<CardConsumption> buildResults(
            Map<String, Decimal>  totalByCard,
            Map<String, Datetime> termStartByCard,
            Map<String, Datetime> termEndByCard,
            Map<String, String>   aggTypeByCard,
            Map<String, Decimal>  consumedByCard) {
        List<CardConsumption> results = new List<CardConsumption>();
        for (String card : totalByCard.keySet()) {
            Decimal total = totalByCard.get(card);
            Decimal consumed = (consumedByCard.containsKey(card) && consumedByCard.get(card) != null)
                ? consumedByCard.get(card) : 0;

            CardConsumption cc = new CardConsumption();
            cc.card         = card;
            cc.aggType      = (aggTypeByCard.containsKey(card) && aggTypeByCard.get(card) != null)
                ? aggTypeByCard.get(card) : 'SUM';
            cc.termStart    = termStartByCard.get(card);
            cc.termEnd      = termEndByCard.get(card);
            cc.totalCredits = total;
            cc.consumed     = consumed;
            cc.remaining    = total - consumed;
            cc.pctConsumed  = (total != 0) ? (consumed / total * 100).setScale(2) : null;
            cc.pctRemaining = (total != 0) ? ((total - consumed) / total * 100).setScale(2) : null;
            cc.note         = (total >= UNLIMITED_THRESHOLD) ? 'UNLIMITED' : '';
            results.add(cc);
        }
        results.sort();
        return results;
    }

    /** Emits the per-card summary to debug logs. Used by the scheduler. */
    public static void logSummary() {
        List<CardConsumption> rows = computeConsumption();
        System.debug('=== Digital Wallet Consumption ===');
        System.debug('Card | AggType | TermStart | TermEnd | TotalCredits | Consumed | Remaining | %Consumed | %Remaining | Note');
        for (CardConsumption c : rows) {
            System.debug(
                c.card + ' | ' + c.aggType + ' | ' + c.termStart + ' | ' + c.termEnd +
                ' | ' + c.totalCredits.toPlainString() + ' | ' + c.consumed.toPlainString() +
                ' | ' + c.remaining.toPlainString() + ' | ' + c.pctConsumed + ' | ' + c.pctRemaining +
                ' | ' + c.note
            );
        }
    }

    /**
     * Computes the current per-card consumption and emails a formatted summary.
     * @param recipients explicit To addresses; when null/empty, defaults to the
     *                   running user's email (i.e. the owner of the scheduled job).
     */
    public static void emailSummary(List<String> recipients) {
        List<String> toAddresses = (recipients == null || recipients.isEmpty())
            ? new List<String>{ UserInfo.getUserEmail() }
            : recipients;
        Messaging.SingleEmailMessage msg = buildSummaryEmail(toAddresses);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ msg });
    }

    /** Convenience overload: emails the summary to the running user. */
    public static void emailSummary() {
        emailSummary(null);
    }

    /**
     * Builds (but does not send) the daily summary email for the given recipients.
     * Exposed so tests can inspect the composed message without sending.
     */
    @TestVisible
    static Messaging.SingleEmailMessage buildSummaryEmail(List<String> recipients) {
        List<CardConsumption> rows = computeConsumption();

        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(recipients);
        msg.setSubject('Digital Wallet Consumption - ' + Date.today().format()
            + ' (' + rows.size() + ' card' + (rows.size() == 1 ? '' : 's') + ')');
        msg.setPlainTextBody(buildTextBody(rows));
        msg.setHtmlBody(buildHtmlBody(rows));
        msg.setSaveAsActivity(false);
        return msg;
    }

    /** Renders the per-card summary as an HTML table for the email body. */
    @TestVisible
    static String buildHtmlBody(List<CardConsumption> rows) {
        String h = '<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#0b0b0b;">';
        h += '<h2 style="margin:0 0 4px;">Digital Wallet Consumption</h2>';
        h += '<p style="margin:0 0 12px;color:#555;">Daily summary &middot; ' + esc(Date.today().format()) + '</p>';

        if (rows == null || rows.isEmpty()) {
            return h + '<p>No active entitlements were found for today.</p></div>';
        }

        h += '<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;border:1px solid #d0d0d0;">';
        h += '<thead><tr style="background:#f2f4f7;">'
           + th('Card') + thR('Total Credits') + thR('Consumed')
           + thR('Remaining') + thR('% Consumed') + thR('% Remaining')
           + '</tr></thead><tbody>';
        for (CardConsumption c : rows) {
            Boolean unlimited = (c.note == 'UNLIMITED');
            h += '<tr style="border-top:1px solid #e5e5e5;">'
               + td(c.card)
               + (unlimited ? tdText('Unlimited') : tdNum(c.totalCredits))
               + tdNum(c.consumed)
               + (unlimited ? tdText('Unlimited') : tdNum(c.remaining))
               + tdPct(c.pctConsumed)
               + tdPct(c.pctRemaining)
               + '</tr>';
        }
        h += '</tbody></table>';
        h += '<p style="margin:12px 0 0;color:#888;font-size:11px;">'
           + 'Generated by DigitalWalletConsumptionScheduler. Consumption is scoped to each card&#39;s '
           + 'active term window; MAX-type cards report the latest Production snapshot.</p>';
        return h + '</div>';
    }

    /** Renders the per-card summary as a plain-text fallback for the email body. */
    @TestVisible
    static String buildTextBody(List<CardConsumption> rows) {
        String s = 'Digital Wallet Consumption - ' + Date.today().format() + '\n\n';
        if (rows == null || rows.isEmpty()) {
            return s + 'No active entitlements were found for today.';
        }

        // Build columns, then size each to its widest value so numbers line up.
        List<String> headers = new List<String>{
            'Card', 'Total Credits', 'Consumed', 'Remaining', '% Consumed', '% Remaining'
        };
        List<Boolean> rightAlign = new List<Boolean>{ false, true, true, true, true, true };
        List<List<String>> cells = new List<List<String>>();
        for (CardConsumption c : rows) {
            Boolean unlimited = (c.note == 'UNLIMITED');
            cells.add(new List<String>{
                c.card,
                unlimited ? 'Unlimited' : fmtNum(c.totalCredits),
                fmtNum(c.consumed),
                unlimited ? 'Unlimited' : fmtNum(c.remaining),
                (c.pctConsumed == null ? '' : c.pctConsumed + '%'),
                (c.pctRemaining == null ? '' : c.pctRemaining + '%')
            });
        }

        List<Integer> widths = new List<Integer>();
        for (Integer col = 0; col < headers.size(); col++) {
            Integer w = headers[col].length();
            for (List<String> row : cells) {
                if (row[col].length() > w) {
                    w = row[col].length();
                }
            }
            widths.add(w);
        }

        s += padRow(headers, widths, rightAlign) + '\n';
        s += ('-').repeat(rowWidth(widths)) + '\n';
        for (List<String> row : cells) {
            s += padRow(row, widths, rightAlign) + '\n';
        }
        return s;
    }

    // Joins one row of cells with 2-space gutters, padding each to its column width.
    static String padRow(List<String> cellsRow, List<Integer> widths, List<Boolean> rightAlign) {
        List<String> parts = new List<String>();
        for (Integer i = 0; i < cellsRow.size(); i++) {
            String v = (cellsRow[i] == null) ? '' : cellsRow[i];
            parts.add(rightAlign[i] ? v.leftPad(widths[i]) : v.rightPad(widths[i]));
        }
        return String.join(parts, '  ');
    }

    // Total width of a padded row including the 2-space gutters between columns.
    static Integer rowWidth(List<Integer> widths) {
        Integer total = 0;
        for (Integer w : widths) {
            total += w;
        }
        return total + (widths.size() - 1) * 2;
    }

    // ---- Small HTML cell helpers ----
    // Left-aligned text header (the Card column).
    static String th(String label) {
        return '<th style="padding:8px 14px;border-bottom:2px solid #d0d0d0;'
             + 'font-weight:600;text-align:left;white-space:nowrap;">' + esc(label) + '</th>';
    }
    // Right-aligned numeric header with a min-width so amount columns stay roomy.
    static String thR(String label) {
        return '<th style="padding:8px 18px;border-bottom:2px solid #d0d0d0;'
             + 'font-weight:600;text-align:right;white-space:nowrap;min-width:120px;">'
             + esc(label) + '</th>';
    }
    static String td(String v) {
        return '<td style="padding:8px 14px;white-space:nowrap;">' + esc(v) + '</td>';
    }
    // Right-aligned free-text numeric cell (e.g. "Unlimited").
    static String tdText(String v) {
        return '<td style="padding:8px 18px;text-align:right;white-space:nowrap;min-width:120px;">'
             + esc(v) + '</td>';
    }
    static String tdNum(Decimal v) {
        return '<td style="padding:8px 18px;text-align:right;white-space:nowrap;min-width:120px;'
             + 'font-variant-numeric:tabular-nums;">' + esc(fmtNum(v)) + '</td>';
    }
    static String tdPct(Decimal v) {
        return '<td style="padding:8px 18px;text-align:right;white-space:nowrap;min-width:100px;'
             + 'font-variant-numeric:tabular-nums;">' + (v == null ? '' : esc(v + '%')) + '</td>';
    }
    // Formats an amount for display: whole numbers show without decimals, otherwise
    // rounded to two places, with thousands separators for readability. Avoids raw
    // Decimal precision artifacts from SUM (e.g. "8296.90339..." or "36.000000").
    @TestVisible
    static String fmtNum(Decimal v) {
        if (v == null) {
            return '';
        }
        Decimal scaled = v.setScale(2, System.RoundingMode.HALF_UP);
        Boolean isWhole = (scaled == Decimal.valueOf(scaled.longValue()));
        Decimal absVal = scaled.abs();
        Long intPart = absVal.longValue();

        // Group the integer part into thousands.
        String intStr = String.valueOf(intPart);
        String grouped = '';
        Integer count = 0;
        for (Integer i = intStr.length() - 1; i >= 0; i--) {
            grouped = intStr.substring(i, i + 1) + grouped;
            count++;
            if (Math.mod(count, 3) == 0 && i > 0) {
                grouped = ',' + grouped;
            }
        }

        String sign = (scaled < 0) ? '-' : '';
        if (isWhole) {
            return sign + grouped;
        }
        String frac = (absVal - intPart).setScale(2, System.RoundingMode.HALF_UP).toPlainString();
        return sign + grouped + '.' + frac.substring(frac.indexOf('.') + 1);
    }
    static String esc(String v) {
        return (v == null) ? '' : v.escapeHtml4();
    }
}

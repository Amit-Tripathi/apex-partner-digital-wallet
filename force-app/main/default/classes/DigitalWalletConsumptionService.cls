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
 *   - Uses TYPED static SOQL against the DMOs so tests can mock responses with the
 *     native SoqlStubProvider pattern (Test.createSoqlStub / Test.createStubQueryRow).
 *     DMO rows cannot be created via DML, so stubbing is the only way to test.
 *   - Query results are assigned to a List before iteration. SOQL for-loops are NOT
 *     supported for DMO SOQL stubs, so we deliberately avoid them.
 *   - Aggregation is done in Apex (not via GROUP BY) so the stub can return plain,
 *     typed DMO rows rather than un-mockable AggregateResult rows.
 *   - Ecosystem-safe: no hardcoded card names or dates. Each card's own active term
 *     window [StartDate, EndDate) is derived from its entitlements, and consumption is
 *     only counted inside that window. Aggregation type is detected per card:
 *       SUM -> cumulative drawdown (sum of unitsconsumed within the term).
 *       MAX -> point-in-time allocation, e.g. storage (latest Production snapshot).
 */
public with sharing class DigitalWalletConsumptionService {

    // Entitlements at/above this quantity are provisioned as effectively "unlimited".
    @TestVisible
    static final Decimal UNLIMITED_THRESHOLD = 1000000000000L;

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

        List<CardConsumption> results = new List<CardConsumption>();
        if (totalByCard.isEmpty()) {
            return results;
        }

        // Overall window bounds the consumption query; per-card windows applied in Apex.
        Datetime overallStart;
        Datetime overallEnd;
        for (String card : totalByCard.keySet()) {
            Datetime s  = termStartByCard.get(card);
            Datetime en = termEndByCard.get(card);
            if (s != null && (overallStart == null || s < overallStart)) {
                overallStart = s;
            }
            if (en != null && (overallEnd == null || en > overallEnd)) {
                overallEnd = en;
            }
        }

        // ---- Step 2: consumption rows for active cards within the overall window ----
        Set<String> cards = totalByCard.keySet();
        Map<String, List<TenantDailyEntitlementConsumption__dlm>> rowsByCard =
            new Map<String, List<TenantDailyEntitlementConsumption__dlm>>();

        List<TenantDailyEntitlementConsumption__dlm> cons = [
            SELECT carddefinitiondevelopername__c, usageaggregationtype__c, unitsconsumed__c,
                   utilizationdate__c, Usage_Business_Environment_Type__c
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c IN :cards
              AND utilizationdate__c >= :overallStart
              AND utilizationdate__c <  :overallEnd
        ];
        for (TenantDailyEntitlementConsumption__dlm c : cons) {
            String card = c.carddefinitiondevelopername__c;
            if (!rowsByCard.containsKey(card)) {
                rowsByCard.put(card, new List<TenantDailyEntitlementConsumption__dlm>());
            }
            rowsByCard.get(card).add(c);
        }

        // ---- Step 3: per-card consumed, honoring each card's own window + agg type ----
        for (String card : totalByCard.keySet()) {
            Decimal  total  = totalByCard.get(card);
            Datetime tStart = termStartByCard.get(card);
            Datetime tEnd   = termEndByCard.get(card);
            List<TenantDailyEntitlementConsumption__dlm> rows = rowsByCard.containsKey(card)
                ? rowsByCard.get(card)
                : new List<TenantDailyEntitlementConsumption__dlm>();

            String aggType = detectAggType(rows);
            Decimal consumed = (aggType == 'MAX')
                ? maxSnapshot(rows, tStart, tEnd)
                : sumConsumed(rows, tStart, tEnd);

            CardConsumption cc = new CardConsumption();
            cc.card         = card;
            cc.aggType      = aggType;
            cc.termStart    = tStart;
            cc.termEnd      = tEnd;
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

    /** Detects the aggregation type for a card. Prefers MAX when a card has mixed types. */
    @TestVisible
    static String detectAggType(List<TenantDailyEntitlementConsumption__dlm> rows) {
        String aggType = 'SUM';
        Boolean found = false;
        for (TenantDailyEntitlementConsumption__dlm r : rows) {
            String t = r.usageaggregationtype__c;
            if (t == 'MAX') {
                return 'MAX';
            }
            if (t != null && !found) {
                aggType = t;
                found = true;
            }
        }
        return aggType;
    }

    /** True if d is inside the half-open window [tStart, tEnd). Null-safe. */
    @TestVisible
    static Boolean inWindow(Datetime d, Datetime tStart, Datetime tEnd) {
        if (d == null) {
            return false;
        }
        if (tStart != null && d < tStart) {
            return false;
        }
        if (tEnd != null && d >= tEnd) {
            return false;
        }
        return true;
    }

    /** Cumulative drawdown: sum of unitsconsumed within the term window. */
    @TestVisible
    static Decimal sumConsumed(List<TenantDailyEntitlementConsumption__dlm> rows, Datetime tStart, Datetime tEnd) {
        Decimal sum = 0;
        for (TenantDailyEntitlementConsumption__dlm r : rows) {
            if (!inWindow(r.utilizationdate__c, tStart, tEnd)) {
                continue;
            }
            if (r.unitsconsumed__c != null) {
                sum += r.unitsconsumed__c;
            }
        }
        return sum;
    }

    /**
     * Point-in-time allocation: latest snapshot within the term window.
     * Prefers the most recent Production reading; falls back to the most recent
     * reading in any environment.
     */
    @TestVisible
    static Decimal maxSnapshot(List<TenantDailyEntitlementConsumption__dlm> rows, Datetime tStart, Datetime tEnd) {
        TenantDailyEntitlementConsumption__dlm bestProd;
        TenantDailyEntitlementConsumption__dlm bestAny;
        for (TenantDailyEntitlementConsumption__dlm r : rows) {
            if (!inWindow(r.utilizationdate__c, tStart, tEnd)) {
                continue;
            }
            if (bestAny == null || r.utilizationdate__c > bestAny.utilizationdate__c) {
                bestAny = r;
            }
            if (r.Usage_Business_Environment_Type__c == 'Production' &&
                (bestProd == null || r.utilizationdate__c > bestProd.utilizationdate__c)) {
                bestProd = r;
            }
        }
        TenantDailyEntitlementConsumption__dlm chosen = (bestProd != null) ? bestProd : bestAny;
        if (chosen == null || chosen.unitsconsumed__c == null) {
            return 0;
        }
        return chosen.unitsconsumed__c;
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
           + th('Card') + th('Type') + th('Total Credits') + th('Consumed')
           + th('Remaining') + th('% Consumed') + th('% Remaining') + th('Note')
           + '</tr></thead><tbody>';
        for (CardConsumption c : rows) {
            h += '<tr style="border-top:1px solid #e5e5e5;">'
               + td(c.card)
               + td(c.aggType)
               + tdNum(c.totalCredits)
               + tdNum(c.consumed)
               + tdNum(c.remaining)
               + tdPct(c.pctConsumed)
               + tdPct(c.pctRemaining)
               + td(c.note)
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
        s += 'Card | Type | Total Credits | Consumed | Remaining | % Consumed | % Remaining | Note\n';
        s += '-----------------------------------------------------------------------------------\n';
        for (CardConsumption c : rows) {
            s += c.card + ' | ' + c.aggType
               + ' | ' + c.totalCredits.toPlainString()
               + ' | ' + c.consumed.toPlainString()
               + ' | ' + c.remaining.toPlainString()
               + ' | ' + (c.pctConsumed == null ? '' : c.pctConsumed + '%')
               + ' | ' + (c.pctRemaining == null ? '' : c.pctRemaining + '%')
               + ' | ' + c.note + '\n';
        }
        return s;
    }

    // ---- Small HTML cell helpers ----
    static String th(String label) {
        return '<th style="padding:6px 12px;border-bottom:2px solid #d0d0d0;'
             + 'font-weight:600;text-align:left;white-space:nowrap;">' + esc(label) + '</th>';
    }
    static String td(String v) {
        return '<td style="padding:6px 12px;white-space:nowrap;">' + esc(v) + '</td>';
    }
    static String tdNum(Decimal v) {
        return '<td style="padding:6px 12px;text-align:right;white-space:nowrap;">'
             + (v == null ? '' : esc(v.toPlainString())) + '</td>';
    }
    static String tdPct(Decimal v) {
        return '<td style="padding:6px 12px;text-align:right;white-space:nowrap;">'
             + (v == null ? '' : esc(v + '%')) + '</td>';
    }
    static String esc(String v) {
        return (v == null) ? '' : v.escapeHtml4();
    }
}

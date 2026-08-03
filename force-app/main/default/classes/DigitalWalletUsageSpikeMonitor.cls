/**
 * DigitalWalletUsageSpikeMonitor
 *
 * Standalone, self-contained daily usage-spike detector for Digital Wallet cards.
 * A "spike" is when the latest day's usage for a card is more than `thresholdPercent`
 * above the trailing MEDIAN of the preceding `baselineDays` days. A trailing median
 * (rather than the single prior day) is used so a rebound off an anomalously low day,
 * or a lone outlier day, doesn't trigger a false alarm. When one or more spikes are
 * found, a single alert email is sent; if none are found, no email is sent.
 *
 * Design notes:
 *   - Deliberately independent of DigitalWalletConsumptionService: it runs its own
 *     TYPED entitlements query against the Data 360 DMOs and its own per-card
 *     consumption lookup, so the existing service/scheduler classes are untouched.
 *   - Daily usage is AGGREGATED AT THE SOURCE (Data 360). Pulling every daily row
 *     exceeds the DMO direct-assignment row cap in production, so recentDailyUsage()
 *     asks Data 360 for just the two most recent days' summed usage per card.
 *   - Aggregate (AggregateResult) DMO queries can't be mocked with SoqlStubProvider,
 *     so recentDailyUsage() is fronted by a @TestVisible seam (usageOverride) and the
 *     pure day-over-day comparison lives in spikeFor(), which tests drive directly.
 *   - Scope: SUM-type cards (daily incremental drawdown). MAX/snapshot cards are
 *     excluded in the query (their daily rows are cumulative snapshots, not usage).
 *
 * Schedule the daily check (07:00 America/New_York given the org's Tahiti timezone):
 *   DigitalWalletUsageSpikeMonitor.scheduleDaily();
 * Tune sensitivity by changing the threshold variable:
 *   DigitalWalletUsageSpikeMonitor.thresholdPercent = 15;
 */
public with sharing class DigitalWalletUsageSpikeMonitor implements Schedulable {

    // Spike threshold, in percent: how far the latest day must exceed the trailing
    // median to be flagged. Change here to tune sensitivity, or override per call via
    // detectSpikes(Decimal) / emailSpikeAlert(..., Decimal).
    @TestVisible
    public static Decimal thresholdPercent = 10;

    // Number of days preceding the latest day that form the trailing-median baseline.
    @TestVisible
    public static Integer baselineDays = 7;

    // Default daily cron: 01:00 org time (Tahiti, GMT-10) == 07:00 US Eastern (EDT).
    @TestVisible
    static final String DEFAULT_CRON = '0 0 1 * * ?';

    // Recipients for the alert email. Null/empty => running user's email.
    @TestVisible
    List<String> recipients;

    // Test seam: aggregate DMO SOQL can't be mocked, so tests inject per-card
    // daily usage (card -> (day -> summed units)) here instead.
    @TestVisible
    static Map<String, Map<Date, Decimal>> usageOverride;

    public DigitalWalletUsageSpikeMonitor() {}

    public DigitalWalletUsageSpikeMonitor(List<String> recipients) {
        this.recipients = recipients;
    }

    /** A single detected usage spike for one card (latest day vs trailing median). */
    public class UsageSpike implements Comparable {
        public String  card;
        public Integer baselineDayCount; // number of prior days in the baseline
        public Decimal baselineUsage;    // trailing median usage of the baseline days
        public Date    latestDate;
        public Decimal latestUsage;
        public Decimal changePct;        // null => "new usage" (baseline median was zero)

        /** Sort by biggest spike first; null changePct (new usage) sorts to the top. */
        public Integer compareTo(Object o) {
            UsageSpike other = (UsageSpike) o;
            if (changePct == null && other.changePct == null) {
                return 0;
            }
            if (changePct == null) {
                return -1;
            }
            if (other.changePct == null) {
                return 1;
            }
            if (changePct == other.changePct) {
                return 0;
            }
            return (changePct > other.changePct) ? -1 : 1;
        }
    }

    // =========================================================================
    // Detection
    // =========================================================================

    /** Detects spikes using the configured static {@link #thresholdPercent}. */
    public static List<UsageSpike> detectSpikes() {
        return detectSpikes(thresholdPercent);
    }

    /**
     * Detects usage spikes for every active SUM-type card by comparing each card's
     * latest day of usage against the trailing median of its preceding baselineDays.
     * @param thresholdPct minimum percent above the trailing median (exclusive) to
     *                     count as a spike.
     * @return list of UsageSpike sorted by largest spike first.
     */
    public static List<UsageSpike> detectSpikes(Decimal thresholdPct) {
        // ---- Step 1: active entitlements -> per-card term window ----
        Map<String, Datetime> termStartByCard = new Map<String, Datetime>();
        Map<String, Datetime> termEndByCard   = new Map<String, Datetime>();

        // --- Standalone SOQL (manual verification) ---------------------------
        // No bind variables; runnable as-is in the SOQL runner / Dev Console.
        // Full runnable copy + explanation: scripts/soql/digitalWallet_entitlements_active.soql
        //   SELECT entitlementcarddefdevlname__c, startdate__c, enddate__c
        //   FROM TenantEntitlementTransaction__dlm
        //   WHERE entitlementtransactiontype__c IN ('Add', 'Reduction')
        //     AND (entitlementtransactionsubtype__c != 'Reparenting'
        //          OR entitlementtransactionsubtype__c = null)
        //     AND startdate__c <= TODAY
        //     AND enddate__c > TODAY
        // --------------------------------------------------------------------
        List<TenantEntitlementTransaction__dlm> ents = [
            SELECT entitlementcarddefdevlname__c, startdate__c, enddate__c
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
            if (e.startdate__c != null &&
                (!termStartByCard.containsKey(card) || e.startdate__c < termStartByCard.get(card))) {
                termStartByCard.put(card, e.startdate__c);
            }
            if (e.enddate__c != null &&
                (!termEndByCard.containsKey(card) || e.enddate__c > termEndByCard.get(card))) {
                termEndByCard.put(card, e.enddate__c);
            }
        }

        List<UsageSpike> spikes = new List<UsageSpike>();
        if (termStartByCard.isEmpty() && termEndByCard.isEmpty()) {
            return spikes;
        }

        Set<String> cards = new Set<String>();
        cards.addAll(termStartByCard.keySet());
        cards.addAll(termEndByCard.keySet());

        // ---- Step 2: per-card recent daily usage (aggregated at source) ----
        for (String card : cards) {
            Map<Date, Decimal> byDay = recentDailyUsage(card, termStartByCard.get(card), termEndByCard.get(card));
            UsageSpike sp = spikeFor(card, byDay, thresholdPct);
            if (sp != null) {
                spikes.add(sp);
            }
        }
        spikes.sort();
        return spikes;
    }

    // Upper bound on daily rows fetched per card. We only need the two most recent
    // days; a small ordered page keeps us far under the DMO direct-assignment row
    // cap while remaining a typed (mockable) query. Daily data has only a handful of
    // environment rows per day, so this comfortably spans many days of usage.
    @TestVisible
    static Integer recentRowLimit = 200;

    /**
     * Returns the most recent (baselineDays + 1) days of usage for a SUM-type card,
     * summed per day and scoped to the card's term window: the latest day plus the
     * trailing baseline window. Uses a bounded, date-descending typed query (not the
     * full daily row set, which exceeds the DMO direct-assignment row cap) and buckets
     * by day in Apex. Typed -> mockable via SoqlStubProvider; tests may also inject
     * via usageOverride.
     */
    @TestVisible
    static Map<Date, Decimal> recentDailyUsage(String card, Datetime tStart, Datetime tEnd) {
        if (usageOverride != null && usageOverride.containsKey(card)) {
            return usageOverride.get(card);
        }
        // --- Standalone SOQL (manual verification) ---------------------------
        // SUM-type cards only (MAX rows are cumulative snapshots, not usage).
        // Replace bind variables with literals (window is half-open [tStart, tEnd)):
        //   :card           -> 'REPLACE_WITH_CARD_DEVELOPER_NAME'
        //   :tStart         -> card's MIN(startdate__c), e.g. 2026-01-01T00:00:00Z
        //   :tEnd           -> card's MAX(enddate__c),   e.g. 2027-01-01T00:00:00Z
        //   :recentRowLimit -> 200 (default)
        // Full runnable copy + explanation: scripts/soql/digitalWallet_recentDailyUsage.soql
        //   SELECT unitsconsumed__c, utilizationdate__c
        //   FROM TenantDailyEntitlementConsumption__dlm
        //   WHERE carddefinitiondevelopername__c = 'REPLACE_WITH_CARD_DEVELOPER_NAME'
        //     AND usageaggregationtype__c != 'MAX'
        //     AND utilizationdate__c >= 2026-01-01T00:00:00Z
        //     AND utilizationdate__c <  2027-01-01T00:00:00Z
        //   ORDER BY utilizationdate__c DESC
        //   LIMIT 200
        // --------------------------------------------------------------------
        List<TenantDailyEntitlementConsumption__dlm> rows = [
            SELECT unitsconsumed__c, utilizationdate__c
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c = :card
              AND usageaggregationtype__c != 'MAX'
              AND utilizationdate__c >= :tStart
              AND utilizationdate__c <  :tEnd
            ORDER BY utilizationdate__c DESC
            LIMIT :recentRowLimit
        ];
        Map<Date, Decimal> byDay = new Map<Date, Decimal>();
        for (TenantDailyEntitlementConsumption__dlm r : rows) {
            if (r.utilizationdate__c == null) {
                continue;
            }
            Date day = r.utilizationdate__c.dateGmt();
            Decimal units = (r.unitsconsumed__c == null) ? 0 : r.unitsconsumed__c;
            byDay.put(day, (byDay.containsKey(day) ? byDay.get(day) : 0) + units);
        }
        // Keep the latest day plus the trailing baseline window.
        Integer keep = baselineDays + 1;
        if (byDay.size() <= keep) {
            return byDay;
        }
        List<Date> days = new List<Date>(byDay.keySet());
        days.sort();
        Map<Date, Decimal> recent = new Map<Date, Decimal>();
        for (Integer i = days.size() - keep; i < days.size(); i++) {
            recent.put(days[i], byDay.get(days[i]));
        }
        return recent;
    }

    /**
     * Pure comparison for a single card: latest day vs the trailing MEDIAN of the
     * preceding days present in byDay. Returns a UsageSpike when the latest day is
     * more than thresholdPct above that median (or when usage appears against a zero
     * baseline). Returns null when there is no spike or fewer than two days of data.
     * A median is used so a single anomalous baseline day (a dip or an outlier)
     * doesn't distort the comparison.
     */
    @TestVisible
    static UsageSpike spikeFor(String card, Map<Date, Decimal> byDay, Decimal thresholdPct) {
        if (byDay == null || byDay.size() < 2) {
            return null;
        }
        List<Date> days = new List<Date>(byDay.keySet());
        days.sort(); // ascending; the last entry is the latest day
        Date latestDay = days[days.size() - 1];
        Decimal latestUsage = byDay.get(latestDay);

        List<Decimal> baselineVals = new List<Decimal>();
        for (Integer i = 0; i < days.size() - 1; i++) {
            Decimal v = byDay.get(days[i]);
            baselineVals.add(v == null ? 0 : v);
        }
        Decimal baseline = median(baselineVals);

        Decimal changePct;
        Boolean isSpike;
        if (baseline == null || baseline == 0) {
            // Zero (or empty) baseline with any positive usage today => "new usage".
            isSpike   = (latestUsage != null && latestUsage > 0);
            changePct = null;
        } else {
            changePct = ((latestUsage - baseline) / baseline * 100).setScale(2);
            isSpike   = (changePct > thresholdPct);
        }

        if (!isSpike) {
            return null;
        }
        UsageSpike sp       = new UsageSpike();
        sp.card             = card;
        sp.baselineDayCount = baselineVals.size();
        sp.baselineUsage    = baseline;
        sp.latestDate       = latestDay;
        sp.latestUsage      = latestUsage;
        sp.changePct        = changePct;
        return sp;
    }

    /** Median of a list of Decimals (ascending). Returns null for an empty list. */
    @TestVisible
    static Decimal median(List<Decimal> values) {
        if (values == null || values.isEmpty()) {
            return null;
        }
        List<Decimal> xs = new List<Decimal>(values);
        xs.sort();
        Integer n = xs.size();
        if (Math.mod(n, 2) == 1) {
            return xs[n / 2];
        }
        return (xs[n / 2 - 1] + xs[n / 2]) / 2;
    }

    // =========================================================================
    // Email
    // =========================================================================

    /** Detects spikes with the configured threshold and emails the running user. */
    public static void emailSpikeAlert() {
        emailSpikeAlert(null, thresholdPercent);
    }

    /** Detects spikes with the configured threshold and emails the given recipients. */
    public static void emailSpikeAlert(List<String> recipients) {
        emailSpikeAlert(recipients, thresholdPercent);
    }

    /**
     * Detects day-over-day spikes and, only if any are found, sends one alert email.
     * @param recipients   explicit To addresses; null/empty => running user's email.
     * @param thresholdPct minimum percent increase to count as a spike.
     */
    public static void emailSpikeAlert(List<String> recipients, Decimal thresholdPct) {
        List<UsageSpike> spikes = detectSpikes(thresholdPct);
        if (spikes.isEmpty()) {
            return; // No spikes -> no email.
        }
        List<String> toAddresses = (recipients == null || recipients.isEmpty())
            ? new List<String>{ UserInfo.getUserEmail() }
            : recipients;
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{
            buildSpikeEmail(toAddresses, spikes, thresholdPct)
        });
    }

    /**
     * Builds (but does not send) the spike alert email for the given spikes.
     * Exposed so tests can inspect the composed message without sending.
     */
    @TestVisible
    static Messaging.SingleEmailMessage buildSpikeEmail(
            List<String> recipients, List<UsageSpike> spikes, Decimal thresholdPct) {
        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(recipients);
        msg.setSubject('Digital Wallet Usage Spike Alert - ' + Date.today().format()
            + ' (' + spikes.size() + ' card' + (spikes.size() == 1 ? '' : 's') + ')');
        msg.setPlainTextBody(buildSpikeTextBody(spikes, thresholdPct));
        msg.setHtmlBody(buildSpikeHtmlBody(spikes, thresholdPct));
        msg.setSaveAsActivity(false);
        return msg;
    }

    /** Renders the detected spikes as an HTML table for the email body. */
    @TestVisible
    static String buildSpikeHtmlBody(List<UsageSpike> spikes, Decimal thresholdPct) {
        String h = '<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#0b0b0b;">';
        h += '<h2 style="margin:0 0 4px;">Digital Wallet Usage Spike Alert</h2>';
        h += '<p style="margin:0 0 12px;color:#555;">' + esc(Date.today().format())
           + ' &middot; latest day more than ' + esc(String.valueOf(thresholdPct))
           + '% above the trailing ' + esc(String.valueOf(baselineDays)) + '-day median</p>';

        if (spikes == null || spikes.isEmpty()) {
            return h + '<p>No usage spikes were detected.</p></div>';
        }

        h += '<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;border:1px solid #d0d0d0;">';
        h += '<thead><tr style="background:#fdecea;">'
           + th('Card') + th('Latest Day') + th('Latest Usage')
           + th('Baseline (median)') + th('Baseline Days') + th('Change vs Median')
           + '</tr></thead><tbody>';
        for (UsageSpike s : spikes) {
            h += '<tr style="border-top:1px solid #e5e5e5;">'
               + td(s.card)
               + td(fmtDate(s.latestDate))
               + tdNum(s.latestUsage)
               + tdNum(s.baselineUsage)
               + td(String.valueOf(s.baselineDayCount))
               + tdChange(s.changePct)
               + '</tr>';
        }
        h += '</tbody></table>';
        h += '<p style="margin:12px 0 0;color:#888;font-size:11px;">'
           + 'Generated by DigitalWalletUsageSpikeMonitor. Compares each card&#39;s latest day of usage '
           + 'against the trailing median of up to ' + esc(String.valueOf(baselineDays)) + ' prior days '
           + '(SUM-type cards only); &quot;new usage&quot; means the baseline median was zero.</p>';
        return h + '</div>';
    }

    /** Renders the detected spikes as a plain-text fallback for the email body. */
    @TestVisible
    static String buildSpikeTextBody(List<UsageSpike> spikes, Decimal thresholdPct) {
        String s = 'Digital Wallet Usage Spike Alert - ' + Date.today().format() + '\n'
                 + 'Latest day greater than ' + thresholdPct + '% above the trailing '
                 + baselineDays + '-day median\n\n';
        if (spikes == null || spikes.isEmpty()) {
            return s + 'No usage spikes were detected.';
        }
        s += 'Card | Latest Day | Latest Usage | Baseline (median) | Baseline Days | Change vs Median\n';
        s += '----------------------------------------------------------------------------------------\n';
        for (UsageSpike sp : spikes) {
            s += sp.card
               + ' | ' + fmtDate(sp.latestDate)
               + ' | ' + fmtNum(sp.latestUsage)
               + ' | ' + fmtNum(sp.baselineUsage)
               + ' | ' + sp.baselineDayCount
               + ' | ' + (sp.changePct == null ? 'new usage' : sp.changePct + '%')
               + '\n';
        }
        return s;
    }

    // =========================================================================
    // Scheduling
    // =========================================================================

    public void execute(SchedulableContext sc) {
        // DMO queries are routed as callouts, which are blocked in Schedulable
        // context. Enqueue the work so it runs where callouts are permitted.
        System.enqueueJob(new DigitalWalletUsageSpikeQueueable(recipients, thresholdPercent));
    }

    /** Schedules the daily spike check, emailing the running user. Returns CronTrigger Id. */
    public static String scheduleDaily() {
        return scheduleDaily(null);
    }

    /** Schedules the daily spike check, emailing the given recipients. Returns CronTrigger Id. */
    public static String scheduleDaily(List<String> recipients) {
        return scheduleWith('Digital Wallet Usage Spike Alert - Daily', DEFAULT_CRON, recipients);
    }

    /** Schedules with a custom name/cron and explicit recipients. Returns CronTrigger Id. */
    public static String scheduleWith(String jobName, String cronExpression, List<String> recipients) {
        return System.schedule(jobName, cronExpression, new DigitalWalletUsageSpikeMonitor(recipients));
    }

    // =========================================================================
    // Small formatting helpers (self-contained; not shared with the service)
    // =========================================================================

    static String fmtDate(Date d) {
        return (d == null) ? '' : d.format();
    }
    static String th(String label) {
        return '<th style="padding:6px 12px;border-bottom:2px solid #d0d0d0;'
             + 'font-weight:600;text-align:left;white-space:nowrap;">' + esc(label) + '</th>';
    }
    static String td(String v) {
        return '<td style="padding:6px 12px;white-space:nowrap;">' + esc(v) + '</td>';
    }
    static String tdNum(Decimal v) {
        return '<td style="padding:6px 12px;text-align:right;white-space:nowrap;">'
             + esc(fmtNum(v)) + '</td>';
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
    static String tdChange(Decimal pct) {
        String txt = (pct == null) ? 'new usage' : ('+' + pct + '%');
        return '<td style="padding:6px 12px;text-align:right;white-space:nowrap;'
             + 'color:#b3261e;font-weight:600;">' + esc(txt) + '</td>';
    }
    static String esc(String v) {
        return (v == null) ? '' : v.escapeHtml4();
    }
}

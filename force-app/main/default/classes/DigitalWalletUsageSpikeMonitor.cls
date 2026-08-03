/**
 * DigitalWalletUsageSpikeMonitor
 *
 * Standalone, self-contained daily usage-spike detector for Digital Wallet cards.
 * A "spike" is a day-over-day jump: the latest day's usage for a card is more than
 * `thresholdPercent` higher than the previous day's usage. When one or more spikes
 * are found, a single alert email is sent; if none are found, no email is sent.
 *
 * Design notes:
 *   - Deliberately independent of DigitalWalletConsumptionService: it runs its own
 *     TYPED static SOQL against the Data 360 DMOs and implements its own term-window
 *     check, so the existing service/scheduler classes are left untouched.
 *   - Uses TYPED static SOQL so tests can mock responses with the native
 *     SoqlStubProvider pattern (Test.createSoqlStub / Test.createStubQueryRow); DMO
 *     rows cannot be created via DML.
 *   - Query results are assigned to a List before iteration. SOQL for-loops are NOT
 *     supported for DMO SOQL stubs, so we avoid them.
 *   - Scope: SUM-type cards (daily incremental drawdown). MAX/snapshot cards are
 *     skipped because their daily rows are cumulative point-in-time snapshots, not
 *     daily usage.
 *
 * Schedule the daily check (07:00 America/New_York given the org's Tahiti timezone):
 *   DigitalWalletUsageSpikeMonitor.scheduleDaily();
 * Tune sensitivity by changing the threshold variable:
 *   DigitalWalletUsageSpikeMonitor.thresholdPercent = 15;
 */
public with sharing class DigitalWalletUsageSpikeMonitor implements Schedulable {

    // Day-over-day spike threshold, in percent. Change here to tune sensitivity,
    // or override per call via detectSpikes(Decimal) / emailSpikeAlert(..., Decimal).
    @TestVisible
    public static Decimal thresholdPercent = 10;

    // Default daily cron: 01:00 org time (Tahiti, GMT-10) == 07:00 US Eastern (EDT).
    @TestVisible
    static final String DEFAULT_CRON = '0 0 1 * * ?';

    // Recipients for the alert email. Null/empty => running user's email.
    @TestVisible
    List<String> recipients;

    public DigitalWalletUsageSpikeMonitor() {}

    public DigitalWalletUsageSpikeMonitor(List<String> recipients) {
        this.recipients = recipients;
    }

    /** A single detected day-over-day usage spike for one card. */
    public class UsageSpike implements Comparable {
        public String  card;
        public Date    previousDate;
        public Decimal previousUsage;
        public Date    latestDate;
        public Decimal latestUsage;
        public Decimal changePct;      // null => "new usage" (previous day was zero)

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
     * Detects day-over-day usage spikes for every active SUM-type card.
     * @param thresholdPct minimum percent increase (exclusive) to count as a spike.
     * @return list of UsageSpike sorted by largest spike first.
     */
    public static List<UsageSpike> detectSpikes(Decimal thresholdPct) {
        // ---- Step 1: active entitlements -> per-card term window ----
        Map<String, Datetime> termStartByCard = new Map<String, Datetime>();
        Map<String, Datetime> termEndByCard   = new Map<String, Datetime>();

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

        // Overall window bounds the consumption query; per-card windows applied in Apex.
        Datetime overallStart;
        Datetime overallEnd;
        for (String card : cards) {
            Datetime s  = termStartByCard.get(card);
            Datetime en = termEndByCard.get(card);
            if (s != null && (overallStart == null || s < overallStart)) {
                overallStart = s;
            }
            if (en != null && (overallEnd == null || en > overallEnd)) {
                overallEnd = en;
            }
        }

        // ---- Step 2: daily consumption rows for those cards within the window ----
        // card -> (day -> summed unitsconsumed)
        Map<String, Map<Date, Decimal>> usageByCardDay = new Map<String, Map<Date, Decimal>>();

        List<TenantDailyEntitlementConsumption__dlm> cons = [
            SELECT carddefinitiondevelopername__c, usageaggregationtype__c,
                   unitsconsumed__c, utilizationdate__c
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c IN :cards
              AND utilizationdate__c >= :overallStart
              AND utilizationdate__c <  :overallEnd
        ];
        for (TenantDailyEntitlementConsumption__dlm c : cons) {
            // SUM-type only: skip point-in-time snapshot cards.
            if (c.usageaggregationtype__c == 'MAX') {
                continue;
            }
            String card = c.carddefinitiondevelopername__c;
            if (card == null || c.utilizationdate__c == null) {
                continue;
            }
            if (!inWindow(c.utilizationdate__c, termStartByCard.get(card), termEndByCard.get(card))) {
                continue;
            }
            Date day = c.utilizationdate__c.dateGmt();
            Decimal units = (c.unitsconsumed__c == null) ? 0 : c.unitsconsumed__c;

            if (!usageByCardDay.containsKey(card)) {
                usageByCardDay.put(card, new Map<Date, Decimal>());
            }
            Map<Date, Decimal> byDay = usageByCardDay.get(card);
            Decimal running = byDay.containsKey(day) ? byDay.get(day) : 0;
            byDay.put(day, running + units);
        }

        // ---- Step 3: per-card day-over-day comparison of the two latest days ----
        for (String card : usageByCardDay.keySet()) {
            Map<Date, Decimal> byDay = usageByCardDay.get(card);
            List<Date> days = new List<Date>(byDay.keySet());
            if (days.size() < 2) {
                continue;
            }
            days.sort(); // ascending; take the last two
            Date prevDay   = days[days.size() - 2];
            Date latestDay = days[days.size() - 1];
            Decimal prevUsage   = byDay.get(prevDay);
            Decimal latestUsage = byDay.get(latestDay);

            Decimal changePct;
            Boolean isSpike;
            if (prevUsage == null || prevUsage == 0) {
                // Zero baseline with any positive usage today => "new usage" spike.
                isSpike   = (latestUsage != null && latestUsage > 0);
                changePct = null;
            } else {
                changePct = ((latestUsage - prevUsage) / prevUsage * 100).setScale(2);
                isSpike   = (changePct > thresholdPct);
            }

            if (!isSpike) {
                continue;
            }
            UsageSpike sp    = new UsageSpike();
            sp.card          = card;
            sp.previousDate  = prevDay;
            sp.previousUsage = prevUsage;
            sp.latestDate    = latestDay;
            sp.latestUsage   = latestUsage;
            sp.changePct     = changePct;
            spikes.add(sp);
        }
        spikes.sort();
        return spikes;
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
           + ' &middot; day-over-day increase greater than ' + esc(String.valueOf(thresholdPct)) + '%</p>';

        if (spikes == null || spikes.isEmpty()) {
            return h + '<p>No usage spikes were detected.</p></div>';
        }

        h += '<table cellspacing="0" cellpadding="0" style="border-collapse:collapse;border:1px solid #d0d0d0;">';
        h += '<thead><tr style="background:#fdecea;">'
           + th('Card') + th('Previous Day') + th('Previous Usage')
           + th('Latest Day') + th('Latest Usage') + th('Change')
           + '</tr></thead><tbody>';
        for (UsageSpike s : spikes) {
            h += '<tr style="border-top:1px solid #e5e5e5;">'
               + td(s.card)
               + td(fmtDate(s.previousDate))
               + tdNum(s.previousUsage)
               + td(fmtDate(s.latestDate))
               + tdNum(s.latestUsage)
               + tdChange(s.changePct)
               + '</tr>';
        }
        h += '</tbody></table>';
        h += '<p style="margin:12px 0 0;color:#888;font-size:11px;">'
           + 'Generated by DigitalWalletUsageSpikeMonitor. Compares the two most recent days with '
           + 'usage per card (SUM-type cards only); &quot;new usage&quot; means the prior day was zero.</p>';
        return h + '</div>';
    }

    /** Renders the detected spikes as a plain-text fallback for the email body. */
    @TestVisible
    static String buildSpikeTextBody(List<UsageSpike> spikes, Decimal thresholdPct) {
        String s = 'Digital Wallet Usage Spike Alert - ' + Date.today().format() + '\n'
                 + 'Day-over-day increase greater than ' + thresholdPct + '%\n\n';
        if (spikes == null || spikes.isEmpty()) {
            return s + 'No usage spikes were detected.';
        }
        s += 'Card | Previous Day | Previous Usage | Latest Day | Latest Usage | Change\n';
        s += '---------------------------------------------------------------------------\n';
        for (UsageSpike sp : spikes) {
            s += sp.card
               + ' | ' + fmtDate(sp.previousDate)
               + ' | ' + (sp.previousUsage == null ? '' : sp.previousUsage.toPlainString())
               + ' | ' + fmtDate(sp.latestDate)
               + ' | ' + (sp.latestUsage == null ? '' : sp.latestUsage.toPlainString())
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
             + (v == null ? '' : esc(v.toPlainString())) + '</td>';
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

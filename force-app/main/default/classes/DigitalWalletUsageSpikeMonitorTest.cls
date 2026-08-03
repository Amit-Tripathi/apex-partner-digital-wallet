/**
 * Tests for DigitalWalletUsageSpikeMonitor.
 *
 * The entitlements DMO query is mocked with the native SoqlStubProvider pattern.
 * Daily usage is aggregated at the source (AggregateResult), which can't be mocked,
 * so per-card daily usage is injected via the monitor's @TestVisible usageOverride
 * seam and the day-over-day logic is driven through spikeFor().
 */
@IsTest
public class DigitalWalletUsageSpikeMonitorTest {

    static final Datetime TERM_START = Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0);
    static final Datetime TERM_END   = Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0);
    static final Date D1 = Date.newInstance(2026, 1, 1);
    static final Date D2 = Date.newInstance(2026, 1, 2);

    static final Date D3 = Date.newInstance(2026, 1, 3);
    static final Datetime DT1 = Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0);
    static final Datetime DT2 = Datetime.newInstanceGmt(2026, 1, 2, 0, 0, 0);
    static final Datetime DT3 = Datetime.newInstanceGmt(2026, 1, 3, 0, 0, 0);

    static List<SObject> entRows  = new List<SObject>();
    static List<SObject> consRows = new List<SObject>();

    public class EntitlementStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            Assert.areEqual(TenantEntitlementTransaction__dlm.sObjectType, sot);
            return entRows;
        }
    }
    public class ConsumptionStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            Assert.areEqual(TenantDailyEntitlementConsumption__dlm.sObjectType, sot);
            return consRows;
        }
    }

    static SObject ent(String card, Datetime startDt, Datetime endDt) {
        return Test.createStubQueryRow(TenantEntitlementTransaction__dlm.sObjectType, new Map<String, Object>{
            'entitlementcarddefdevlname__c' => card,
            'startdate__c'                  => startDt,
            'enddate__c'                    => endDt
        });
    }
    static SObject con(Decimal units, Datetime utilDt) {
        return Test.createStubQueryRow(TenantDailyEntitlementConsumption__dlm.sObjectType, new Map<String, Object>{
            'carddefinitiondevelopername__c' => 'C',
            'usageaggregationtype__c'        => 'SUM',
            'unitsconsumed__c'               => units,
            'utilizationdate__c'             => utilDt
        });
    }

    static void registerEnt() {
        Test.createSoqlStub(TenantEntitlementTransaction__dlm.sObjectType, new EntitlementStub());
    }
    static void registerCons() {
        Test.createSoqlStub(TenantDailyEntitlementConsumption__dlm.sObjectType, new ConsumptionStub());
    }

    // One card ('FlexCredits') with two consecutive days of usage, injected via seam.
    static void seedTwoDayUsage(Decimal day1, Decimal day2) {
        entRows = new List<SObject>{ ent('FlexCredits', TERM_START, TERM_END) };
        DigitalWalletUsageSpikeMonitor.usageOverride = new Map<String, Map<Date, Decimal>>{
            'FlexCredits' => new Map<Date, Decimal>{ D1 => day1, D2 => day2 }
        };
    }

    // =========================================================================
    // detectSpikes (entitlements stubbed; usage injected)
    // =========================================================================

    @IsTest
    static void spikePresentIsFlagged() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerEnt();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Test.stopTest();

        Assert.areEqual(1, spikes.size(), 'A 20% jump over the median should be flagged at 10%');
        DigitalWalletUsageSpikeMonitor.UsageSpike sp = spikes[0];
        Assert.areEqual('FlexCredits', sp.card);
        Assert.areEqual(1000, sp.baselineUsage.intValue(), 'Median of a single prior day is that day');
        Assert.areEqual(1, sp.baselineDayCount);
        Assert.areEqual(1200, sp.latestUsage.intValue());
        Assert.areEqual(20, sp.changePct.intValue(), 'Change should be +20%');
        Assert.areEqual(D2, sp.latestDate);
    }

    @IsTest
    static void noSpikeWhenBelowThreshold() {
        seedTwoDayUsage(1000, 1050); // +5%
        registerEnt();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Test.stopTest();

        Assert.areEqual(0, spikes.size(), 'A 5% jump should not be flagged at a 10% threshold');
    }

    @IsTest
    static void zeroBaselineIsNewUsage() {
        seedTwoDayUsage(0, 500); // 0 -> positive
        registerEnt();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Test.stopTest();

        Assert.areEqual(1, spikes.size(), 'Zero-to-positive usage should be flagged');
        Assert.isNull(spikes[0].changePct, 'New usage should have a null change percent');
        Assert.areEqual(500, spikes[0].latestUsage.intValue());
    }

    @IsTest
    static void thresholdVariableIsHonored() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerEnt();

        Test.startTest();
        DigitalWalletUsageSpikeMonitor.thresholdPercent = 25;
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(); // no-arg uses the static variable
        Test.stopTest();

        Assert.areEqual(0, spikes.size(),
            'A 20% jump should not be flagged when the threshold variable is 25%');
    }

    @IsTest
    static void detectSpikesSortsMultipleCardsAndSkipsNonSpikes() {
        entRows = new List<SObject>{
            ent('CardA', TERM_START, TERM_END),
            ent('CardB', TERM_START, TERM_END),
            ent('CardC', TERM_START, TERM_END),
            ent('CardE', TERM_START, TERM_END),
            ent('CardF', TERM_START, TERM_END),
            ent('CardG', TERM_START, TERM_END),
            ent(null,    TERM_START, TERM_END) // null card -> skipped
        };
        DigitalWalletUsageSpikeMonitor.usageOverride = new Map<String, Map<Date, Decimal>>{
            'CardA' => new Map<Date, Decimal>{ D1 => 1000, D2 => 1200 }, // +20%
            'CardB' => new Map<Date, Decimal>{ D1 => 1000, D2 => 2000 }, // +100%
            'CardC' => new Map<Date, Decimal>{ D1 => 0,    D2 => 500 },  // new usage
            'CardE' => new Map<Date, Decimal>{ D1 => 1000, D2 => 1200 }, // +20% (== CardA)
            'CardF' => new Map<Date, Decimal>{ D1 => 0,    D2 => 300 },  // new usage
            'CardG' => new Map<Date, Decimal>{ D1 => 1000 }              // single day -> skipped
        };
        registerEnt();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Test.stopTest();

        Assert.areEqual(5, spikes.size(),
            'CardA, CardB, CardC, CardE, CardF spike; single-day CardG and null card are skipped');
        Assert.isNull(spikes[0].changePct, 'New-usage spikes sort first');
        Assert.isNull(spikes[1].changePct, 'Both new-usage spikes sort first');
    }

    // =========================================================================
    // Pure day-over-day logic + seams
    // =========================================================================

    @IsTest
    static void spikeForCoversAllBranches() {
        // Fewer than two days -> null.
        Assert.isNull(DigitalWalletUsageSpikeMonitor.spikeFor('C',
            new Map<Date, Decimal>{ D2 => 100 }, 10), 'Need two days to compare');
        // Below threshold -> null.
        Assert.isNull(DigitalWalletUsageSpikeMonitor.spikeFor('C',
            new Map<Date, Decimal>{ D1 => 1000, D2 => 1050 }, 10), '+5% is below a 10% threshold');
        // Above threshold -> spike with percent.
        DigitalWalletUsageSpikeMonitor.UsageSpike up =
            DigitalWalletUsageSpikeMonitor.spikeFor('C', new Map<Date, Decimal>{ D1 => 1000, D2 => 1300 }, 10);
        Assert.areEqual(30, up.changePct.intValue(), '+30% should be flagged');
        // Zero baseline -> new usage (null pct).
        DigitalWalletUsageSpikeMonitor.UsageSpike nu =
            DigitalWalletUsageSpikeMonitor.spikeFor('C', new Map<Date, Decimal>{ D1 => 0, D2 => 400 }, 10);
        Assert.isNull(nu.changePct, 'Zero baseline yields new usage');
    }

    @IsTest
    static void recentDailyUsageHonorsOverride() {
        Map<Date, Decimal> injected = new Map<Date, Decimal>{ D1 => 10, D2 => 20 };
        DigitalWalletUsageSpikeMonitor.usageOverride =
            new Map<String, Map<Date, Decimal>>{ 'C' => injected };
        Assert.areEqual(injected,
            DigitalWalletUsageSpikeMonitor.recentDailyUsage('C', TERM_START, TERM_END),
            'The override should short-circuit the query');
    }

    @IsTest
    static void recentDailyUsageBucketsAndTrimsToWindow() {
        // baselineDays=1 => keep the latest day + 1 trailing day (2 total).
        DigitalWalletUsageSpikeMonitor.baselineDays = 1;
        consRows = new List<SObject>{
            con(100, DT3), con(50, DT3), // day 3 => 150
            con(80, DT2),                // day 2 => 80
            con(40, DT1),                // day 1 => 40 (dropped: outside the kept window)
            con(999, null)               // null date => skipped
        };
        registerCons();

        Test.startTest();
        Map<Date, Decimal> byDay =
            DigitalWalletUsageSpikeMonitor.recentDailyUsage('C', TERM_START, TERM_END);
        Test.stopTest();

        Assert.areEqual(2, byDay.size(), 'Only latest day + baselineDays should remain');
        Assert.areEqual(150, byDay.get(D3).intValue(), 'Same-day rows should be summed');
        Assert.areEqual(80, byDay.get(D2).intValue(), 'Second most recent day should be kept');
        Assert.isFalse(byDay.containsKey(D1), 'The oldest day should be dropped');
    }

    @IsTest
    static void medianHandlesOddEvenAndEmpty() {
        Assert.isNull(DigitalWalletUsageSpikeMonitor.median(new List<Decimal>()),
            'Empty list has no median');
        Assert.areEqual(5, DigitalWalletUsageSpikeMonitor.median(new List<Decimal>{ 5 }).intValue());
        Assert.areEqual(2, DigitalWalletUsageSpikeMonitor.median(
            new List<Decimal>{ 3, 1, 2 }).intValue(), 'Odd count -> middle value');
        Assert.areEqual(2.5, DigitalWalletUsageSpikeMonitor.median(
            new List<Decimal>{ 1, 2, 3, 4 }), 'Even count -> mean of the middle two');
    }

    @IsTest
    static void trailingMedianSuppressesReboundFalsePositive() {
        // Mirrors the real FlexCredits case: steady ~4,500/day, a near-zero dip, then
        // a partial rebound (788). Against the prior day (36) that is +2089%, but
        // against the trailing median (~4,456) it is a DECREASE -> no spike.
        Map<Date, Decimal> byDay = new Map<Date, Decimal>{
            Date.newInstance(2026, 7, 25) => 4500,
            Date.newInstance(2026, 7, 26) => 4456,
            Date.newInstance(2026, 7, 27) => 4532,
            Date.newInstance(2026, 7, 28) => 4448,
            Date.newInstance(2026, 7, 29) => 36,
            Date.newInstance(2026, 7, 30) => 788
        };
        Assert.isNull(DigitalWalletUsageSpikeMonitor.spikeFor('FlexCredits', byDay, 10),
            'A rebound that stays below the trailing median must not be flagged');
    }

    @IsTest
    static void trailingMedianStillCatchesRealSpike() {
        // Latest day well above the trailing median (robust to a lone 48k outlier).
        Map<Date, Decimal> byDay = new Map<Date, Decimal>{
            Date.newInstance(2026, 7, 27) => 9351,
            Date.newInstance(2026, 7, 28) => 9193,
            Date.newInstance(2026, 7, 29) => 48646,
            Date.newInstance(2026, 7, 30) => 8257,
            Date.newInstance(2026, 7, 31) => 7917,
            Date.newInstance(2026, 8, 1)  => 8296,
            Date.newInstance(2026, 8, 2)  => 14751
        };
        DigitalWalletUsageSpikeMonitor.UsageSpike sp =
            DigitalWalletUsageSpikeMonitor.spikeFor('PlatformServicesCard', byDay, 10);
        Assert.isNotNull(sp, 'A genuine jump over the trailing median should be flagged');
        Assert.isTrue(sp.changePct > 10, 'Change over the median should exceed the threshold');
        Assert.areEqual(6, sp.baselineDayCount, 'Baseline should use the six prior days');
    }

    @IsTest
    static void recentDailyUsageReturnsFewerThanTwoDays() {
        consRows = new List<SObject>{ con(40, DT1) };
        registerCons();

        Map<Date, Decimal> byDay =
            DigitalWalletUsageSpikeMonitor.recentDailyUsage('C', TERM_START, TERM_END);
        Assert.areEqual(1, byDay.size(), 'A single day of data returns a single-entry map');
        Assert.areEqual(40, byDay.get(D1).intValue());
    }

    @IsTest
    static void numberFormattingIsClean() {
        Assert.areEqual('', DigitalWalletUsageSpikeMonitor.fmtNum(null));
        Assert.areEqual('788', DigitalWalletUsageSpikeMonitor.fmtNum(788.000000),
            'Whole numbers should drop the decimal');
        Assert.areEqual('14751.03', DigitalWalletUsageSpikeMonitor.fmtNum(14751.034118),
            'Precision artifacts should round to two places');
    }

    @IsTest
    static void comparatorOrdersSpikes() {
        DigitalWalletUsageSpikeMonitor.UsageSpike newUsage = new DigitalWalletUsageSpikeMonitor.UsageSpike();
        newUsage.changePct = null;
        DigitalWalletUsageSpikeMonitor.UsageSpike newUsage2 = new DigitalWalletUsageSpikeMonitor.UsageSpike();
        newUsage2.changePct = null;
        DigitalWalletUsageSpikeMonitor.UsageSpike small = new DigitalWalletUsageSpikeMonitor.UsageSpike();
        small.changePct = 20;
        DigitalWalletUsageSpikeMonitor.UsageSpike big = new DigitalWalletUsageSpikeMonitor.UsageSpike();
        big.changePct = 100;

        Assert.areEqual(0,  newUsage.compareTo(newUsage2), 'Two new-usage spikes are equal');
        Assert.areEqual(-1, newUsage.compareTo(big),       'New usage sorts before a numeric spike');
        Assert.areEqual(1,  big.compareTo(newUsage),       'A numeric spike sorts after new usage');
        Assert.areEqual(0,  small.compareTo(small),        'Equal percentages compare equal');
        Assert.areEqual(-1, big.compareTo(small),          'A bigger spike sorts first');
        Assert.areEqual(1,  small.compareTo(big),          'A smaller spike sorts later');
    }

    // =========================================================================
    // Email
    // =========================================================================

    @IsTest
    static void buildSpikeEmailComposesMessage() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerEnt();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Messaging.SingleEmailMessage msg =
            DigitalWalletUsageSpikeMonitor.buildSpikeEmail(
                new List<String>{ 'me@example.com' }, spikes, 10);
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'me@example.com' }, msg.getToAddresses());
        Assert.isTrue(msg.getSubject().startsWith('Digital Wallet Usage Spike Alert'),
            'Subject should describe the alert');
        Assert.isTrue(msg.getSubject().contains('(1 card)'),
            'Subject should reflect the single spiking card');
        Assert.isTrue(msg.getHtmlBody().contains('FlexCredits'),
            'HTML body should list the card');
        Assert.isTrue(msg.getHtmlBody().contains('%'),
            'HTML body should show the change percent');
        Assert.isTrue(msg.getPlainTextBody().contains('FlexCredits'),
            'Plain-text body should list the card');
    }

    @IsTest
    static void bodyBuildersHandleEmptySpikes() {
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> none =
            new List<DigitalWalletUsageSpikeMonitor.UsageSpike>();
        Assert.isTrue(
            DigitalWalletUsageSpikeMonitor.buildSpikeHtmlBody(none, 10).contains('No usage spikes'),
            'HTML body should state no spikes were detected');
        Assert.isTrue(
            DigitalWalletUsageSpikeMonitor.buildSpikeTextBody(none, 10).contains('No usage spikes'),
            'Text body should state no spikes were detected');
    }

    @IsTest
    static void emailSpikeAlertRunsCleanlyWhenSpikeExists() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerEnt();

        Test.startTest();
        try {
            DigitalWalletUsageSpikeMonitor.emailSpikeAlert(null, 10);
        } catch (Exception e) {
            Assert.fail('emailSpikeAlert should not throw: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void emailSpikeAlertOverloadsRunCleanly() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerEnt();

        Test.startTest();
        try {
            DigitalWalletUsageSpikeMonitor.emailSpikeAlert();
            DigitalWalletUsageSpikeMonitor.emailSpikeAlert(new List<String>{ 'me@example.com' });
        } catch (Exception e) {
            Assert.fail('emailSpikeAlert overloads should not throw: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void emailSpikeAlertNoSendWhenNoSpike() {
        seedTwoDayUsage(1000, 1050); // +5% -> no spike -> no send
        registerEnt();

        Test.startTest();
        try {
            DigitalWalletUsageSpikeMonitor.emailSpikeAlert(new List<String>{ 'me@example.com' }, 10);
        } catch (Exception e) {
            Assert.fail('emailSpikeAlert should not throw when there is nothing to send: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.areEqual(0, Limits.getEmailInvocations(),
            'No email should be sent when no spike is detected');
    }

    // =========================================================================
    // Scheduling / async
    // =========================================================================

    @IsTest
    static void noArgConstructorIsUsable() {
        Assert.isNotNull(new DigitalWalletUsageSpikeMonitor(),
            'The no-arg constructor should produce an instance');
    }

    @IsTest
    static void executeEnqueuesQueueable() {
        seedTwoDayUsage(1000, 1200); // +20% => spike
        registerEnt();

        Test.startTest();
        new DigitalWalletUsageSpikeMonitor(new List<String>{ 'me@example.com' }).execute(null);
        Test.stopTest();

        List<AsyncApexJob> jobs = [
            SELECT Status, ApexClass.Name
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
              AND ApexClass.Name = 'DigitalWalletUsageSpikeQueueable'
        ];
        Assert.areEqual(1, jobs.size(), 'execute() should enqueue the spike Queueable');
        Assert.areEqual('Completed', jobs[0].Status,
            'The enqueued Queueable should run to completion');
    }

    @IsTest
    static void scheduleDailyDefaultCreatesCronTrigger() {
        entRows = new List<SObject>();
        registerEnt();
        String jobId = DigitalWalletUsageSpikeMonitor.scheduleDaily();
        Assert.isNotNull(jobId, 'scheduleDaily should return a CronTrigger Id');
        Assert.areEqual(1, [SELECT Id FROM CronTrigger WHERE Id = :jobId].size(),
            'scheduleDaily should create a CronTrigger');
    }

    @IsTest
    static void scheduleDailyWithRecipientsCreatesCronTrigger() {
        entRows = new List<SObject>();
        registerEnt();
        String jobId = DigitalWalletUsageSpikeMonitor.scheduleDaily(new List<String>{ 'me@example.com' });
        Assert.isNotNull(jobId, 'scheduleDaily(recipients) should return a CronTrigger Id');
        Assert.areEqual(1, [SELECT Id FROM CronTrigger WHERE Id = :jobId].size(),
            'scheduleDaily(recipients) should create a CronTrigger');
    }

    @IsTest
    static void scheduleCreatesCronTrigger() {
        entRows = new List<SObject>();
        registerEnt();

        Test.startTest();
        String jobId = DigitalWalletUsageSpikeMonitor.scheduleWith(
            'DW Spike Test Job', '0 0 0 1 1 ? 2099', new List<String>{ 'me@example.com' });
        Test.stopTest();

        Assert.isNotNull(jobId, 'System.schedule should return a CronTrigger Id');
        Assert.areEqual(1, [SELECT Id FROM CronTrigger WHERE Id = :jobId].size(),
            'A CronTrigger should have been created');
    }
}

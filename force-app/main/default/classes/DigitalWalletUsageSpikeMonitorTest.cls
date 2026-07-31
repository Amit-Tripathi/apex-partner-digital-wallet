/**
 * Tests for DigitalWalletUsageSpikeMonitor.
 *
 * The Data 360 DMOs (TenantEntitlementTransaction__dlm /
 * TenantDailyEntitlementConsumption__dlm) cannot be created via DML, so query
 * responses are mocked with the native SoqlStubProvider pattern
 * (Test.createSoqlStub + Test.createStubQueryRow).
 */
@IsTest
public class DigitalWalletUsageSpikeMonitorTest {

    // Rows returned by the stubs for the current test (set before createSoqlStub).
    static List<SObject> entRows  = new List<SObject>();
    static List<SObject> consRows = new List<SObject>();

    // Default term window comfortably enclosing the utilization dates below.
    static final Datetime TERM_START = Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0);
    static final Datetime TERM_END   = Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0);

    // ---- SOQL stubs (one per DMO type) ----
    public class EntitlementStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String stubbedQuery, Map<String, Object> bindVars) {
            Assert.areEqual(TenantEntitlementTransaction__dlm.sObjectType, sot);
            return entRows;
        }
    }
    public class ConsumptionStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String stubbedQuery, Map<String, Object> bindVars) {
            Assert.areEqual(TenantDailyEntitlementConsumption__dlm.sObjectType, sot);
            return consRows;
        }
    }

    // ---- Row builders ----
    static SObject ent(String card, Datetime startDt, Datetime endDt) {
        return Test.createStubQueryRow(TenantEntitlementTransaction__dlm.sObjectType, new Map<String, Object>{
            'entitlementcarddefdevlname__c' => card,
            'startdate__c'                  => startDt,
            'enddate__c'                    => endDt
        });
    }
    static SObject con(String card, String aggType, Decimal units, Datetime utilDt) {
        return Test.createStubQueryRow(TenantDailyEntitlementConsumption__dlm.sObjectType, new Map<String, Object>{
            'carddefinitiondevelopername__c' => card,
            'usageaggregationtype__c'        => aggType,
            'unitsconsumed__c'               => units,
            'utilizationdate__c'             => utilDt
        });
    }

    static void registerStubs() {
        Test.createSoqlStub(TenantEntitlementTransaction__dlm.sObjectType, new EntitlementStub());
        Test.createSoqlStub(TenantDailyEntitlementConsumption__dlm.sObjectType, new ConsumptionStub());
    }

    // Two consecutive days of usage for a single SUM card.
    static void seedTwoDayUsage(Decimal day1, Decimal day2) {
        entRows = new List<SObject>{ ent('FlexCredits', TERM_START, TERM_END) };
        consRows = new List<SObject>{
            con('FlexCredits', 'SUM', day1, Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0)),
            con('FlexCredits', 'SUM', day2, Datetime.newInstanceGmt(2026, 1, 2, 0, 0, 0))
        };
    }

    @IsTest
    static void spikePresentIsFlagged() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerStubs();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Test.stopTest();

        Assert.areEqual(1, spikes.size(), 'A 20% jump should be flagged at a 10% threshold');
        DigitalWalletUsageSpikeMonitor.UsageSpike sp = spikes[0];
        Assert.areEqual('FlexCredits', sp.card);
        Assert.areEqual(1000, sp.previousUsage.intValue());
        Assert.areEqual(1200, sp.latestUsage.intValue());
        Assert.areEqual(20, sp.changePct.intValue(), 'Change should be +20%');
        Assert.areEqual(Date.newInstance(2026, 1, 1), sp.previousDate);
        Assert.areEqual(Date.newInstance(2026, 1, 2), sp.latestDate);
    }

    @IsTest
    static void noSpikeWhenBelowThreshold() {
        seedTwoDayUsage(1000, 1050); // +5%
        registerStubs();

        Test.startTest();
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(10);
        Test.stopTest();

        Assert.areEqual(0, spikes.size(), 'A 5% jump should not be flagged at a 10% threshold');
    }

    @IsTest
    static void zeroBaselineIsNewUsage() {
        seedTwoDayUsage(0, 500); // 0 -> positive
        registerStubs();

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
        registerStubs();

        Test.startTest();
        // Raise the configurable variable above the actual change => no spike.
        DigitalWalletUsageSpikeMonitor.thresholdPercent = 25;
        List<DigitalWalletUsageSpikeMonitor.UsageSpike> spikes =
            DigitalWalletUsageSpikeMonitor.detectSpikes(); // no-arg uses the static variable
        Test.stopTest();

        Assert.areEqual(0, spikes.size(),
            'A 20% jump should not be flagged when the threshold variable is 25%');
    }

    @IsTest
    static void buildSpikeEmailComposesMessage() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerStubs();

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
    static void emailSpikeAlertRunsCleanlyWhenSpikeExists() {
        seedTwoDayUsage(1000, 1200); // +20%
        registerStubs();

        Test.startTest();
        // Apex suppresses real sends in tests, so assert the path runs cleanly.
        try {
            DigitalWalletUsageSpikeMonitor.emailSpikeAlert(null, 10);
        } catch (Exception e) {
            Assert.fail('emailSpikeAlert should not throw: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void emailSpikeAlertNoSendWhenNoSpike() {
        seedTwoDayUsage(1000, 1050); // +5% -> no spike -> no send
        registerStubs();

        Test.startTest();
        try {
            DigitalWalletUsageSpikeMonitor.emailSpikeAlert(new List<String>{ 'me@example.com' }, 10);
        } catch (Exception e) {
            Assert.fail('emailSpikeAlert should not throw when there is nothing to send: ' + e.getMessage());
        }
        Test.stopTest();
        // No spike => no email; assert the send counter stayed at zero.
        Assert.areEqual(0, Limits.getEmailInvocations(),
            'No email should be sent when no spike is detected');
    }

    @IsTest
    static void scheduleCreatesCronTrigger() {
        entRows  = new List<SObject>();
        consRows = new List<SObject>();
        registerStubs();

        Test.startTest();
        // Cron far in the future so the job doesn't fire during the test.
        String jobId = DigitalWalletUsageSpikeMonitor.scheduleWith(
            'DW Spike Test Job', '0 0 0 1 1 ? 2099', new List<String>{ 'me@example.com' });
        Test.stopTest();

        Assert.isNotNull(jobId, 'System.schedule should return a CronTrigger Id');
        List<CronTrigger> triggers = [SELECT Id FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(1, triggers.size(), 'A CronTrigger should have been created');
    }
}

/**
 * Tests for DigitalWalletConsumptionScheduler.
 *
 * DMO queries executed by the scheduled job are mocked with SoqlStubProvider so
 * the job runs without touching real Data 360 data.
 */
@IsTest
public class DigitalWalletConsumptionSchedulerTest {

    public class EntStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            return new List<SObject>{
                Test.createStubQueryRow(TenantEntitlementTransaction__dlm.sObjectType, new Map<String, Object>{
                    'entitlementcarddefdevlname__c' => 'FlexCredits',
                    'quantity__c'                   => 400000,
                    'startdate__c'                  => Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0),
                    'enddate__c'                    => Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0),
                    'entitlementtransactiontype__c' => 'Add'
                })
            };
        }
    }
    public class ConStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            return new List<SObject>{
                Test.createStubQueryRow(TenantDailyEntitlementConsumption__dlm.sObjectType, new Map<String, Object>{
                    'carddefinitiondevelopername__c'     => 'FlexCredits',
                    'usageaggregationtype__c'            => 'SUM',
                    'unitsconsumed__c'                   => 1000,
                    'utilizationdate__c'                 => Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0),
                    'Usage_Business_Environment_Type__c' => 'Production'
                })
            };
        }
    }

    static void registerStubs() {
        Test.createSoqlStub(TenantEntitlementTransaction__dlm.sObjectType, new EntStub());
        Test.createSoqlStub(TenantDailyEntitlementConsumption__dlm.sObjectType, new ConStub());
    }

    @IsTest
    static void executeEnqueuesQueueable() {
        registerStubs();
        Test.startTest();
        // execute() only enqueues; the enqueued Queueable runs at stopTest() and
        // exercises emailSummary() -> computeConsumption() against the stubs.
        // Apex suppresses real sends in tests, so assert the path runs cleanly.
        new DigitalWalletConsumptionScheduler().execute(null);
        Test.stopTest();

        List<AsyncApexJob> jobs = [
            SELECT Status, ApexClass.Name
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
              AND ApexClass.Name = 'DigitalWalletConsumptionEmailQueueable'
        ];
        Assert.areEqual(1, jobs.size(), 'execute() should enqueue the email Queueable');
        Assert.areEqual('Completed', jobs[0].Status,
            'The enqueued Queueable should run to completion against the stubs');
    }

    @IsTest
    static void scheduleDailyCreatesCronTrigger() {
        registerStubs();
        // No startTest/stopTest so the recurring job is created but not fired here.
        String jobId = DigitalWalletConsumptionScheduler.scheduleDaily();
        Assert.isNotNull(jobId, 'scheduleDaily should return a CronTrigger Id');
        List<CronTrigger> triggers = [
            SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId
        ];
        Assert.areEqual(1, triggers.size(), 'scheduleDaily should create a CronTrigger');
        Assert.areEqual('0 0 7 * * ?', triggers[0].CronExpression,
            'Default schedule should fire at 07:00 each morning');
    }

    @IsTest
    static void scheduleDailyWithRecipientsCreatesCronTrigger() {
        registerStubs();
        String jobId = DigitalWalletConsumptionScheduler.scheduleDaily(
            new List<String>{ 'me@example.com' });
        Assert.isNotNull(jobId, 'scheduleDaily(recipients) should return a CronTrigger Id');
        List<CronTrigger> triggers = [SELECT Id FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(1, triggers.size(),
            'scheduleDaily(recipients) should create a CronTrigger');
    }

    @IsTest
    static void scheduleCreatesCronTrigger() {
        registerStubs();
        Test.startTest();
        // Cron far in the future so the job doesn't fire during the test.
        String jobId = DigitalWalletConsumptionScheduler.scheduleWith(
            'DW Consumption Test Job', '0 0 0 1 1 ? 2099');
        Test.stopTest();

        Assert.isNotNull(jobId, 'System.schedule should return a CronTrigger Id');
        List<CronTrigger> triggers = [
            SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId
        ];
        Assert.areEqual(1, triggers.size(), 'A CronTrigger should have been created');
    }
}

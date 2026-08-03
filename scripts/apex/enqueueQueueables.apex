/**
 * Post-deployment validation: directly enqueue the Digital Wallet Queueables.
 *
 * The scheduled jobs run in Schedulable context, which blocks the Data 360 (Data
 * Cloud) DMO callouts. The fix moves that work into Queueables that implement
 * Database.AllowsCallouts. This script enqueues those Queueables directly (without
 * waiting for the cron schedule) so you can validate, right after deployment, that:
 *   1. the callout succeeds in Queueable context (no CalloutException), and
 *   2. the summary / spike-alert email is delivered.
 *
 * Run:
 *   sf apex run --file scripts/apex/enqueueQueueables.apex --target-org <alias>
 *
 * Then check delivery + job status:
 *   - Your inbox (default recipient is the running user's email).
 *   - Setup > Apex Jobs, or:
 *       SELECT Id, ApexClass.Name, Status, ExtendedStatus, NumberOfErrors,
 *              CompletedDate
 *       FROM AsyncApexJob
 *       WHERE JobType = 'Queueable'
 *       ORDER BY CreatedDate DESC
 */

// Recipients for both emails. Leave null to default to the running user's email,
// or set explicit addresses, e.g. new List<String>{ 'me@example.com' }.
List<String> recipients = null;

// Day-over-day spike threshold (percent) for the spike-alert validation.
Decimal spikeThresholdPct = DigitalWalletUsageSpikeMonitor.thresholdPercent;

// 1) Consumption summary Queueable (always sends a summary).
Id consumptionJobId = System.enqueueJob(
    new DigitalWalletConsumptionEmailQueueable(recipients));
System.debug('Enqueued DigitalWalletConsumptionEmailQueueable: ' + consumptionJobId);

// 2) Usage-spike Queueable (only sends if a day-over-day spike is detected).
Id spikeJobId = System.enqueueJob(
    new DigitalWalletUsageSpikeQueueable(recipients, spikeThresholdPct));
System.debug('Enqueued DigitalWalletUsageSpikeQueueable: ' + spikeJobId);

System.debug('Recipient default (when null): ' + UserInfo.getUserEmail());
System.debug('Spike threshold: ' + spikeThresholdPct + '%');
System.debug('Both jobs enqueued. Check AsyncApexJob status and your inbox.');

/**
 * DigitalWalletConsumptionScheduler
 *
 * Schedulable wrapper that runs DigitalWalletConsumptionService on a cron schedule
 * and emails the per-card consumption summary.
 *
 * Schedule the default morning email (07:00 org time) to yourself:
 *   DigitalWalletConsumptionScheduler.scheduleDaily();
 *
 * Email specific recipients:
 *   DigitalWalletConsumptionScheduler.scheduleDaily(new List<String>{ 'me@example.com' });
 *
 * Or with a custom job name / cron expression:
 *   DigitalWalletConsumptionScheduler.scheduleWith('DW Consumption', '0 0 7 * * ?');
 */
public with sharing class DigitalWalletConsumptionScheduler implements Schedulable {

    // Default: every day at 07:00 (org time) so the summary lands each morning.
    @TestVisible
    static final String DEFAULT_CRON = '0 0 7 * * ?';

    // Recipients for the summary email. Null/empty => running user's email.
    @TestVisible
    List<String> recipients;

    public DigitalWalletConsumptionScheduler() {}

    public DigitalWalletConsumptionScheduler(List<String> recipients) {
        this.recipients = recipients;
    }

    public void execute(SchedulableContext sc) {
        // DMO queries are routed as callouts, which are blocked in Schedulable
        // context. Enqueue the work so it runs where callouts are permitted.
        System.enqueueJob(new DigitalWalletConsumptionEmailQueueable(recipients));
    }

    /** Schedules the daily 07:00 email to the running user. Returns the CronTrigger Id. */
    public static String scheduleDaily() {
        return scheduleDaily(null);
    }

    /** Schedules the daily 07:00 email to the given recipients. Returns the CronTrigger Id. */
    public static String scheduleDaily(List<String> recipients) {
        return scheduleWith('Digital Wallet Consumption - Daily Email', DEFAULT_CRON, recipients);
    }

    /** Schedules with a custom name/cron, emailing the running user. Returns the CronTrigger Id. */
    public static String scheduleWith(String jobName, String cronExpression) {
        return scheduleWith(jobName, cronExpression, null);
    }

    /** Schedules with a custom name/cron and explicit recipients. Returns the CronTrigger Id. */
    public static String scheduleWith(String jobName, String cronExpression, List<String> recipients) {
        return System.schedule(jobName, cronExpression, new DigitalWalletConsumptionScheduler(recipients));
    }
}

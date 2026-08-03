// Reschedule the Digital Wallet Consumption daily email to fire at 07:00 America/New_York.
// The scheduling user's timezone is Pacific/Tahiti (GMT-10); Eastern is GMT-4 (EDT),
// so 07:00 Eastern == 01:00 Tahiti => cron '0 0 1 * * ?'.
String jobName = 'Digital Wallet Consumption - Daily Email';

// Abort any existing schedule with this name so we can re-create it.
for (CronTrigger ct : [
        SELECT Id FROM CronTrigger
        WHERE CronJobDetail.Name = :jobName]) {
    System.abortJob(ct.Id);
}

String jobId = DigitalWalletConsumptionScheduler.scheduleWith(jobName, '0 0 1 * * ?');
System.debug('Rescheduled job Id: ' + jobId);
System.debug('Recipient default: ' + UserInfo.getUserEmail());

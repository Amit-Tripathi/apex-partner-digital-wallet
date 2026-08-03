// Schedules the Digital Wallet Consumption daily email at 07:00 org time.
// Default recipient is the running user's email; pass a List<String> to override.
String jobId = DigitalWalletConsumptionScheduler.scheduleDaily();
System.debug('Scheduled job Id: ' + jobId);
System.debug('Recipient default: ' + UserInfo.getUserEmail());

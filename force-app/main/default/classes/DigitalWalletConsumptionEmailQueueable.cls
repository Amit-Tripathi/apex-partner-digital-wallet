/**
 * DigitalWalletConsumptionEmailQueueable
 *
 * Runs the Digital Wallet consumption summary and emails it from an async
 * Queueable context. This exists because the underlying query hits Data 360
 * (Data Cloud) DMOs, which the platform routes as outbound callouts. Callouts
 * are unconditionally blocked in Schedulable context, so the scheduler only
 * enqueues this job; the actual DMO query and email happen here where
 * Database.AllowsCallouts permits the callout.
 */
public with sharing class DigitalWalletConsumptionEmailQueueable
        implements Queueable, Database.AllowsCallouts {

    // Recipients for the summary email. Null/empty => running user's email.
    @TestVisible
    final List<String> recipients;

    /**
     * @param recipients explicit To addresses for the summary email; when
     *                   null/empty, the service defaults to the running user's
     *                   email (i.e. the owner of the scheduled job).
     */
    public DigitalWalletConsumptionEmailQueueable(List<String> recipients) {
        this.recipients = recipients;
    }

    /**
     * Queueable entry point. Runs in async context where Database.AllowsCallouts
     * permits the Data 360 DMO callout, then computes and emails the per-card
     * consumption summary.
     * @param ctx the Queueable execution context supplied by the platform.
     */
    public void execute(QueueableContext ctx) {
        DigitalWalletConsumptionService.emailSummary(recipients);
    }
}

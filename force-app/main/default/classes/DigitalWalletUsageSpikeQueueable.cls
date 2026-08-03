/**
 * DigitalWalletUsageSpikeQueueable
 *
 * Runs the Digital Wallet day-over-day usage-spike check and sends the alert
 * (only if any spikes are found) from an async Queueable context. Like the
 * consumption summary, spike detection queries Data 360 (Data Cloud) DMOs,
 * which the platform routes as outbound callouts. Callouts are blocked in
 * Schedulable context, so the monitor's scheduled job only enqueues this
 * Queueable, where Database.AllowsCallouts permits the callout.
 */
public with sharing class DigitalWalletUsageSpikeQueueable
        implements Queueable, Database.AllowsCallouts {

    // Recipients for the alert email. Null/empty => running user's email.
    @TestVisible
    final List<String> recipients;

    // Day-over-day spike threshold, in percent.
    @TestVisible
    final Decimal thresholdPct;

    /**
     * @param recipients   explicit To addresses for the alert email; when
     *                     null/empty, the monitor defaults to the running user's
     *                     email (i.e. the owner of the scheduled job).
     * @param thresholdPct minimum day-over-day percent increase that counts as a
     *                     spike; captured at enqueue time so the async run uses
     *                     the same sensitivity as the schedule.
     */
    public DigitalWalletUsageSpikeQueueable(List<String> recipients, Decimal thresholdPct) {
        this.recipients   = recipients;
        this.thresholdPct = thresholdPct;
    }

    /**
     * Queueable entry point. Runs in async context where Database.AllowsCallouts
     * permits the Data 360 DMO callout, then detects day-over-day spikes and
     * sends the alert email only when one or more spikes are found.
     * @param ctx the Queueable execution context supplied by the platform.
     */
    public void execute(QueueableContext ctx) {
        DigitalWalletUsageSpikeMonitor.emailSpikeAlert(recipients, thresholdPct);
    }
}

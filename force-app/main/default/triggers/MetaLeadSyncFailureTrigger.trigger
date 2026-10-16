/**
 * @description  Thin trigger — delegates to MetaLeadSyncFailureNotifier so a failed Meta
 *               lead is surfaced (in-app notification + optional email) the moment it's
 *               dead-lettered, rather than relying on someone checking a list view.
 */
trigger MetaLeadSyncFailureTrigger on Meta_Lead_Sync_Failure__c (after insert) {
    MetaLeadSyncFailureNotifier.notify(Trigger.new);
}
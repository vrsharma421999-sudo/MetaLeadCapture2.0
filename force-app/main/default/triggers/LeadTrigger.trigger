/**
 * @description  Thin trigger — delegates to LeadConversionSyncHandler, which queues an
 *               outbound Meta Conversions API event whenever a Meta-sourced Lead's Status
 *               changes to a value mapped in Meta_Lead_Stage_Mapping__c.
 */
trigger LeadTrigger on Lead (after update) {
    LeadConversionSyncHandler.handleStatusChange(Trigger.new, Trigger.oldMap);
}
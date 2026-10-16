/**
 * @class        LeadConversionSyncHandler
 * @description  Detects Lead.Status transitions on Meta-sourced Leads (Meta_Leadgen_Id__c
 *               populated) and queues a Meta_Conversion_Event__c for each one whose new
 *               Status has an Active mapping in Meta_Lead_Stage_Mapping__c — this is the
 *               "report lead qualification back to Meta" half of the integration described in
 *               Meta's CRM/Conversions-API-for-Leads documentation, so ad delivery can
 *               optimize toward leads that actually convert, not just raw form fills.
 *
 *               Deliberately does no callout here — only a DML insert of the tracking row, so
 *               this can run safely inside the Lead update trigger for any internal user
 *               without needing Named Credential/External Credential access wired to every
 *               profile that edits Leads. The actual send to Meta happens later, out of band,
 *               via MetaConversionSyncQueueable/MetaConversionSyncScheduler.
 */
public without sharing class LeadConversionSyncHandler {

    public static void handleStatusChange(List<Lead> newLeads, Map<Id, Lead> oldLeadsById) {
        Map<String, String> stageMapping = getActiveStageMapping();
        if (stageMapping.isEmpty()) {
            return;
        }

        List<Meta_Conversion_Event__c> events = new List<Meta_Conversion_Event__c>();
        for (Lead newLead : newLeads) {
            Lead oldLead = oldLeadsById.get(newLead.Id);
            Boolean statusChanged = oldLead != null && newLead.Status != oldLead.Status;
            if (!statusChanged || String.isBlank(newLead.Meta_Leadgen_Id__c)) {
                continue;
            }

            String eventName = stageMapping.get(newLead.Status);
            if (String.isBlank(eventName)) {
                System.debug(LoggingLevel.INFO, '[LeadConversionSyncHandler] Lead ' + newLead.Id + ' Status -> "' + newLead.Status
                    + '" has no active Meta_Lead_Stage_Mapping__c row — not queuing an event');
                continue;
            }

            events.add(new Meta_Conversion_Event__c(
                Lead__c = newLead.Id,
                Leadgen_Id__c = newLead.Meta_Leadgen_Id__c,
                Event_Name__c = eventName,
                Event_Time__c = System.now(),
                Status__c = 'Pending'
            ));
            System.debug(LoggingLevel.INFO, '[LeadConversionSyncHandler] Lead ' + newLead.Id + ' Status -> "' + newLead.Status
                + '" mapped to event_name="' + eventName + '" — queuing Meta_Conversion_Event__c');
        }

        if (!events.isEmpty()) {
            Database.insert(events, AccessLevel.SYSTEM_MODE);
            System.debug(LoggingLevel.INFO, '[LeadConversionSyncHandler] inserted ' + events.size()
                + ' Meta_Conversion_Event__c row(s) — will send on the next MetaConversionSyncQueueable run');
        }
    }

    @TestVisible private static Map<String, String> stageMappingCache;

    private static Map<String, String> getActiveStageMapping() {
        if (stageMappingCache == null) {
            stageMappingCache = new Map<String, String>();
            for (Meta_Lead_Stage_Mapping__c m : [
                SELECT Salesforce_Status__c, Meta_Event_Name__c
                FROM Meta_Lead_Stage_Mapping__c
                WHERE Active__c = true
            ]) {
                if (String.isNotBlank(m.Salesforce_Status__c)) {
                    stageMappingCache.put(m.Salesforce_Status__c, m.Meta_Event_Name__c);
                }
            }
        }
        return stageMappingCache;
    }
}
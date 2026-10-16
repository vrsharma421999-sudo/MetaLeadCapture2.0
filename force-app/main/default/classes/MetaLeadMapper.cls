/**
 * @class        MetaLeadMapper
 * @description  Pure mapping/upsert logic for turning a Meta Graph API leadgen payload
 *               (the JSON body of GET /{leadgen_id}?fields=field_data,...) into a Lead.
 *               Extracted out of MetaLeadFetchQueueable so the exact same logic can be
 *               re-run from MetaLeadSyncFailureResend against a Raw_Payload__c stored on a
 *               Meta_Lead_Sync_Failure__c record, without duplicating field-mapping rules
 *               in two places.
 *
 *               Field mapping from Meta's field_data[].name keys to Lead field API names is
 *               config-driven via Meta_Field_Map__c (a List Custom Setting, so each org's
 *               mapping rows are its own data and are never overwritten by deploying this
 *               package's Apex/LWC to another org). Each row is either scoped to one form
 *               (Form_Id__c populated — since two Meta forms can reuse the same question key
 *               for different purposes) or a global fallback (Form_Id__c blank, used only when
 *               the form that sent the lead has no mapping of its own for that key). Name
 *               splitting (full_name/first_name/last_name) is handled directly rather than via
 *               config, since Lead.LastName is mandatory and Meta's most common form field is
 *               full_name. Managed via the Meta Lead Capture Setup page.
 *
 *               Deliberately contains no callouts, no error logging, and no dead-lettering —
 *               callers (MetaLeadFetchQueueable, MetaLeadSyncFailureResend) own try/catch and
 *               decide what happens on failure.
 */
public without sharing class MetaLeadMapper {

    public static Lead upsertLeadFromPayload(String leadgenId, Map<String, Object> payload) {
        List<Lead> existing = [
            SELECT Id, IsConverted
            FROM Lead
            WHERE Meta_Leadgen_Id__c = :leadgenId
            LIMIT 1
        ];
        // Already converted — nothing left to sync from our side on redelivery/resend, and a
        // converted Lead's fields are typically locked for edit anyway.
        if (!existing.isEmpty() && existing[0].IsConverted) {
            System.debug(LoggingLevel.INFO, '[MetaLeadMapper] leadgen_id=' + leadgenId + ' already converted (Lead '
                + existing[0].Id + ') — skipping, nothing to update');
            return existing[0];
        }
        System.debug(LoggingLevel.INFO, '[MetaLeadMapper] leadgen_id=' + leadgenId + ' -> '
            + (existing.isEmpty() ? 'creating new Lead' : 'updating existing Lead ' + existing[0].Id));

        Lead lead = existing.isEmpty() ? new Lead() : new Lead(Id = existing[0].Id);
        lead.Meta_Leadgen_Id__c = leadgenId;
        lead.Meta_Ad_Id__c = (String) payload.get('ad_id');
        lead.Meta_Ad_Set_Id__c = (String) payload.get('adset_id');
        lead.Meta_Campaign_Id__c = (String) payload.get('campaign_id');
        lead.Meta_Form_Id__c = (String) payload.get('form_id');
        lead.Meta_Page_Id__c = (String) payload.get('page_id');
        lead.Meta_Lead_Created_Time__c = parseCreatedTime(payload.get('created_time'));

        Object rawFieldData = payload.get('field_data');
        lead.Meta_Raw_Field_Data__c = rawFieldData != null ? truncate(JSON.serialize(rawFieldData), 32000) : null;

        Map<String, String> fieldData = flattenFieldData((List<Object>) rawFieldData);
        System.debug(LoggingLevel.INFO, '[MetaLeadMapper] leadgen_id=' + leadgenId + ' raw form fields: ' + fieldData.keySet());
        applyFieldMapping(lead, fieldData, lead.Meta_Form_Id__c);
        applyNameMapping(lead, fieldData);

        if (String.isBlank(lead.LastName)) {
            lead.LastName = 'Meta Lead ' + leadgenId;
        }
        if (String.isBlank(lead.Company)) {
            lead.Company = 'Unknown (Meta Lead Ad)';
        }
        setLeadSource(lead);

        // SYSTEM_MODE: this runs from the guest-user-initiated webhook path, and the Guest
        // User license does not allow the "Edit" object permission at all (only Create/Read)
        // — without this, a redelivered/duplicate leadgen_id would fail to update.
        if (existing.isEmpty()) {
            Database.insert(lead, AccessLevel.SYSTEM_MODE);
        } else {
            Database.update(lead, AccessLevel.SYSTEM_MODE);
        }
        System.debug(LoggingLevel.INFO, '[MetaLeadMapper] leadgen_id=' + leadgenId + ' saved as Lead ' + lead.Id
            + ' (LastName=' + lead.LastName + ', Company=' + lead.Company + ', LeadSource=' + lead.LeadSource + ')');
        return lead;
    }

    @TestVisible
    private static Map<String, String> flattenFieldData(List<Object> fieldData) {
        Map<String, String> flat = new Map<String, String>();
        if (fieldData == null) {
            return flat;
        }
        for (Object entryObj : fieldData) {
            Map<String, Object> entry = (Map<String, Object>) entryObj;
            String name = (String) entry.get('name');
            List<Object> values = (List<Object>) entry.get('values');
            if (String.isNotBlank(name) && values != null && !values.isEmpty()) {
                flat.put(name.toLowerCase(), String.valueOf(values[0]));
            }
        }
        return flat;
    }

    private static void applyFieldMapping(Lead lead, Map<String, String> fieldData, String formId) {
        Map<String, String> globalMapping = getFieldMapping();
        Map<String, String> formMapping = getFormFieldMapping(formId);
        // Schema.SObjectType.Lead.fields.getMap() keys are all lowercase — must lowercase
        // sfField too or every mapped field silently fails this check and gets skipped.
        Map<String, Schema.SObjectField> leadFields = Schema.SObjectType.Lead.fields.getMap();

        for (String metaKey : fieldData.keySet()) {
            // A form-specific row (Form_Id__c populated) always wins over the global fallback
            // (Form_Id__c blank) for the same Meta_Field_Key__c, so per-form overrides don't
            // need the global row removed.
            String sfField = formMapping.containsKey(metaKey) ? formMapping.get(metaKey) : globalMapping.get(metaKey);
            if (String.isBlank(sfField) || !leadFields.containsKey(sfField.toLowerCase())) {
                continue;
            }
            lead.put(sfField, fieldData.get(metaKey));
        }
    }

    private static void applyNameMapping(Lead lead, Map<String, String> fieldData) {
        String firstName = fieldData.get('first_name');
        String lastName = fieldData.get('last_name');
        String fullName = fieldData.get('full_name');

        if (String.isBlank(lastName) && String.isNotBlank(fullName)) {
            List<String> parts = fullName.trim().split(' ', 2);
            firstName = String.isBlank(firstName) ? parts[0] : firstName;
            lastName = parts.size() > 1 ? parts[1] : parts[0];
        }
        if (String.isNotBlank(firstName)) {
            lead.FirstName = firstName;
        }
        if (String.isNotBlank(lastName)) {
            lead.LastName = lastName;
        }
    }

    private static void setLeadSource(Lead lead) {
        lead.Meta_Lead_Source_Detail__c = 'Meta Lead Ads';
        if (getActiveLeadSourceValues().contains('Facebook')) {
            lead.LeadSource = 'Facebook';
        }
    }

    @TestVisible private static Set<String> activeLeadSourceValuesCache;

    private static Set<String> getActiveLeadSourceValues() {
        if (activeLeadSourceValuesCache == null) {
            activeLeadSourceValuesCache = new Set<String>();
            for (Schema.PicklistEntry entry : Lead.LeadSource.getDescribe().getPicklistValues()) {
                if (entry.isActive()) {
                    activeLeadSourceValuesCache.add(entry.getValue());
                }
            }
        }
        return activeLeadSourceValuesCache;
    }

    // Global fallback (Form_Id__c blank) — key => Lead field API name. Kept as a flat map
    // (rather than folded into formMappingCache) so existing tests that prime this directly
    // keep working unchanged.
    @TestVisible private static Map<String, String> mappingCache;

    // Per-form overrides: formId => (metaKey => Lead field API name).
    @TestVisible private static Map<String, Map<String, String>> formMappingCache;

    private static Map<String, String> getFieldMapping() {
        if (mappingCache == null) {
            mappingCache = new Map<String, String>();
            // getAll() (the generated cached accessor) is always readable by Apex — including
            // the Guest User running the webhook that (transitively) invokes this class —
            // regardless of sharing/FLS; a plain SOQL SELECT against a Custom Setting does NOT
            // get this same bypass for Guest context.
            for (Meta_Field_Map__c m : Meta_Field_Map__c.getAll().values()) {
                if (m.Active__c && String.isNotBlank(m.Meta_Field_Key__c) && String.isBlank(m.Form_Id__c)) {
                    mappingCache.put(m.Meta_Field_Key__c.toLowerCase(), m.Salesforce_Field_API_Name__c);
                }
            }
        }
        return mappingCache;
    }

    private static Map<String, String> getFormFieldMapping(String formId) {
        if (formMappingCache == null) {
            formMappingCache = new Map<String, Map<String, String>>();
            for (Meta_Field_Map__c m : Meta_Field_Map__c.getAll().values()) {
                if (m.Active__c && String.isNotBlank(m.Meta_Field_Key__c) && String.isNotBlank(m.Form_Id__c)) {
                    if (!formMappingCache.containsKey(m.Form_Id__c)) {
                        formMappingCache.put(m.Form_Id__c, new Map<String, String>());
                    }
                    formMappingCache.get(m.Form_Id__c).put(m.Meta_Field_Key__c.toLowerCase(), m.Salesforce_Field_API_Name__c);
                }
            }
        }
        if (String.isBlank(formId) || !formMappingCache.containsKey(formId)) {
            return new Map<String, String>();
        }
        return formMappingCache.get(formId);
    }

    /**
     * @description Meta returns created_time in two different shapes depending on source: the
     *              webhook POST payload sends a raw Unix timestamp (int), but the Graph API's
     *              GET /{leadgen_id} response — the only one that ever reaches this method —
     *              sends an ISO 8601 string instead (e.g. "2026-09-23T06:16:27+0000"). Handles
     *              both so a Meta format change on either side doesn't throw a TypeException.
     */
    @TestVisible
    private static Datetime parseCreatedTime(Object raw) {
        if (raw == null) {
            return null;
        }
        String rawStr = String.valueOf(raw);
        if (rawStr.isNumeric()) {
            return Datetime.newInstance(Long.valueOf(rawStr) * 1000);
        }
        try {
            String normalized = rawStr.replace('T', ' ');
            Integer offsetIdx = normalized.indexOf('+');
            if (offsetIdx < 0) {
                offsetIdx = normalized.lastIndexOf('-');
            }
            if (offsetIdx > 10) {
                normalized = normalized.substring(0, offsetIdx);
            }
            return Datetime.valueOfGmt(normalized.trim());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[MetaLeadMapper.parseCreatedTime] could not parse "' + rawStr + '": ' + e.getMessage());
            return null;
        }
    }

    @TestVisible
    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return '';
        }
        return s.length() > maxLen
            ? s.substring(0, maxLen) + '... [truncated, total ' + s.length() + ' chars]'
            : s;
    }
}
/**
 * @class        MetaFormSyncService
 * @description  Discovers every leadgen form on each active Meta_Page_Setting__c Page
 *               (GET /{page-id}/leadgen_forms) and that form's questions
 *               (GET /{form-id}?fields=questions), then creates an unmapped, inactive
 *               Meta_Field_Map__c row (Form_Id__c populated) for any question not already
 *               represented — so a new form/question shows up on the Field Mapping tab ready
 *               for an admin to assign a Salesforce field and activate, rather than needing to
 *               be typed in by hand. Existing mapping rows (including ones an admin already
 *               configured or deactivated) are left untouched.
 */
public without sharing class MetaFormSyncService {

    public class SyncResult {
        @AuraEnabled public Integer formsFound = 0;
        @AuraEnabled public Integer questionsFound = 0;
        @AuraEnabled public Integer newMappingsAdded = 0;
        @AuraEnabled public List<String> messages = new List<String>();
    }

    public static SyncResult syncForms() {
        SyncResult result = new SyncResult();

        List<String> pageIds = new List<String>();
        for (Meta_Page_Setting__c p : Meta_Page_Setting__c.getAll().values()) {
            if (p.Active__c && String.isNotBlank(p.Page_Id__c)) {
                pageIds.add(p.Page_Id__c);
            }
        }

        Set<String> existingKeys = new Set<String>();
        for (Meta_Field_Map__c m : Meta_Field_Map__c.getAll().values()) {
            if (String.isNotBlank(m.Form_Id__c) && String.isNotBlank(m.Meta_Field_Key__c)) {
                existingKeys.add(uniqueKey(m.Form_Id__c, m.Meta_Field_Key__c));
            }
        }

        List<Meta_Field_Map__c> toInsert = new List<Meta_Field_Map__c>();
        for (String pageId : pageIds) {
            for (Object formObj : listFormsForPage(pageId)) {
                Map<String, Object> form = (Map<String, Object>) formObj;
                String formId = form.get('id') != null ? String.valueOf(form.get('id')) : null;
                String formName = (String) form.get('name');
                if (String.isBlank(formId)) {
                    continue;
                }
                result.formsFound++;

                for (Object qObj : getFormQuestions(formId)) {
                    Map<String, Object> q = (Map<String, Object>) qObj;
                    String key = (String) q.get('key');
                    String label = (String) q.get('label');
                    if (String.isBlank(key)) {
                        continue;
                    }
                    result.questionsFound++;

                    String uKey = uniqueKey(formId, key);
                    if (existingKeys.contains(uKey)) {
                        continue;
                    }
                    existingKeys.add(uKey);

                    toInsert.add(new Meta_Field_Map__c(
                        Name = uKey.length() > 80 ? uKey.substring(0, 80) : uKey,
                        Form_Id__c = formId,
                        Form_Name__c = formName,
                        Meta_Field_Key__c = key,
                        Meta_Field_Label__c = label,
                        Salesforce_Field_API_Name__c = null,
                        Active__c = false
                    ));
                    result.newMappingsAdded++;
                    result.messages.add('New question on "' + formName + '": ' + label + ' (' + key
                        + ') — assign a Salesforce field and activate it on the Field Mapping tab');
                }
            }
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, AccessLevel.SYSTEM_MODE);
        }
        return result;
    }

    private static String uniqueKey(String formId, String metaFieldKey) {
        return formId + '_' + metaFieldKey.toLowerCase();
    }

    // =====================================================================
    // Live lookups for the "New Lead Capture Mapping" picker on the Field Mapping tab —
    // unlike syncForms() above, these don't write any rows; they just read straight from
    // Graph API so the picker always reflects the current state of the form in Meta.
    // =====================================================================

    public class FormOption {
        @AuraEnabled public String formId;
        @AuraEnabled public String formName;
        @AuraEnabled public String pageId;
        @AuraEnabled public String pageName;
    }

    public static List<FormOption> listAllForms() {
        List<FormOption> result = new List<FormOption>();
        for (Meta_Page_Setting__c p : Meta_Page_Setting__c.getAll().values()) {
            if (!p.Active__c || String.isBlank(p.Page_Id__c)) {
                continue;
            }
            for (Object formObj : listFormsForPage(p.Page_Id__c)) {
                Map<String, Object> form = (Map<String, Object>) formObj;
                if (form.get('id') == null) {
                    continue;
                }
                FormOption fo = new FormOption();
                fo.formId = String.valueOf(form.get('id'));
                fo.formName = (String) form.get('name');
                fo.pageId = p.Page_Id__c;
                fo.pageName = p.Page_Name__c;
                result.add(fo);
            }
        }
        return result;
    }

    public class QuestionOption {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
    }

    public static List<QuestionOption> listFormQuestions(String formId) {
        List<QuestionOption> result = new List<QuestionOption>();
        for (Object qObj : getFormQuestions(formId)) {
            Map<String, Object> q = (Map<String, Object>) qObj;
            if (q.get('key') == null) {
                continue;
            }
            QuestionOption qo = new QuestionOption();
            qo.key = (String) q.get('key');
            qo.label = (String) q.get('label');
            result.add(qo);
        }
        return result;
    }

    /**
     * @description GET /{page-id}/leadgen_forms using the System User token — returns every
     *              leadgen form that exists on the Page (regardless of active/paused status).
     */
    private static List<Object> listFormsForPage(String pageId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Meta_Graph_API/' + pageId + '/leadgen_forms?fields=id,name&limit=200');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'listFormsForPage', 'MetaFormSyncService', 'Page ' + pageId, new MetaFormSyncException(res.getBody()),
                pageId, null, null, 'Graph API /leadgen_forms returned ' + res.getStatusCode()
            );
            return new List<Object>();
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> data = (List<Object>) body.get('data');
        return data != null ? data : new List<Object>();
    }

    private static List<Object> getFormQuestions(String formId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Meta_Graph_API/' + formId + '?fields=questions');
        req.setMethod('GET');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            CreateErrorLog.logFacebookError(
                'getFormQuestions', 'MetaFormSyncService', 'Form ' + formId, new MetaFormSyncException(res.getBody()),
                null, null, formId, 'Graph API /{form-id}?fields=questions returned ' + res.getStatusCode()
            );
            return new List<Object>();
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> questions = (List<Object>) body.get('questions');
        return questions != null ? questions : new List<Object>();
    }

    public class MetaFormSyncException extends Exception {}
}
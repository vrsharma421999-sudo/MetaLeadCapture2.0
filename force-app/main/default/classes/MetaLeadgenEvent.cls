/**
 * @class        MetaLeadgenEvent
 * @description  A single (leadgen_id, page_id) pair extracted from one `leadgen` webhook
 *               change entry. page_id is carried alongside leadgen_id from the very start of
 *               the pipeline (MetaLeadWebhook.extractLeadgenIds) so MetaLeadFetchQueueable can
 *               pick the right Page's access token (Meta_Page_Config__c) BEFORE calling the
 *               Graph API — required once an org has more than one connected Facebook Page.
 */
public class MetaLeadgenEvent {
    public String leadgenId;
    public String pageId;

    public MetaLeadgenEvent(String leadgenId, String pageId) {
        this.leadgenId = leadgenId;
        this.pageId = pageId;
    }
}
package cn.suixing.suixing_loc

import org.junit.Assert.*
import org.junit.Test

class MapShareInboxTest {
    @Test fun latestShareIsConsumedOnce() {
        val inbox = MapShareInbox()
        assertTrue(inbox.receive("android.intent.action.SEND", "text/plain", "old"))
        assertTrue(inbox.receive("android.intent.action.SEND", "text/plain", " https://surl.amap.com/new "))
        assertEquals("https://surl.amap.com/new", inbox.peek()?.get("text"))
        assertEquals("https://surl.amap.com/new", inbox.take()?.get("text"))
        assertNull(inbox.take())
    }

    @Test fun unsupportedActionsAndBinaryFilesDoNotReplacePendingText() {
        val inbox = MapShareInbox()
        inbox.receive("android.intent.action.SEND", "text/uri-list", "https://surl.amap.com/test")
        assertFalse(inbox.receive("android.intent.action.VIEW", "text/plain", "wrong"))
        assertFalse(inbox.receive("android.intent.action.SEND", "image/png", "wrong"))
        assertEquals("https://surl.amap.com/test", inbox.take()?.get("text"))
    }

    @Test fun oversizedOrEmptySharesBecomeBoundedErrors() {
        val inbox = MapShareInbox()
        inbox.receive("android.intent.action.SEND", "text/plain", "x".repeat(8193))
        assertNull(inbox.peek()?.get("text"))
        assertNotNull(inbox.take()?.get("error"))
        inbox.receive("android.intent.action.SEND", "text/plain", null)
        assertNotNull(inbox.take()?.get("error"))
    }

    @Test fun unconsumedShareSurvivesActivityRecreation() {
        val recreated = MapShareInbox()
        recreated.restore("https://surl.amap.com/test", null)
        assertEquals("https://surl.amap.com/test", recreated.take()?.get("text"))
        assertNull(recreated.take())
    }
}

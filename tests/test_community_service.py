import sqlite3
import unittest

from app.community_schema import initialize_community
from app.community_service import (
    CommunityDenied, create_comment, create_post, delete_post, list_posts, report_post,
)

class CommunityServiceTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        initialize_community(self.conn)
        self.conn.executemany(
            "INSERT INTO community_users(id,display_name) VALUES(?,?)",
            [("alice","Alice"),("bob","Bob"),("outsider","Outsider")],
        )
        self.conn.execute(
            "INSERT INTO community_groups(id,title,university,visibility) VALUES('group1','Math','LUH','private')"
        )
        self.conn.executemany(
            "INSERT INTO community_memberships(group_id,user_id,role) VALUES('group1',?,?)",
            [("alice","owner"),("bob","member")],
        )
        self.conn.commit()

    def tearDown(self):
        self.conn.close()

    def test_member_can_post_comment_and_report(self):
        post = create_post(self.conn, actor_id="alice", group_id="group1", title="Question", body="How?")
        comment = create_comment(self.conn, actor_id="bob", post_id=post, body="Answer")
        report = report_post(self.conn, actor_id="bob", post_id=post, reason="Please review")
        self.assertTrue(comment and report)
        self.assertEqual(len(list_posts(self.conn, actor_id="bob", group_id="group1")), 1)

    def test_outsider_cannot_read_or_write(self):
        post = create_post(self.conn, actor_id="alice", group_id="group1", title="Secret", body="Notes")
        with self.assertRaises(CommunityDenied):
            list_posts(self.conn, actor_id="outsider", group_id="group1")
        with self.assertRaises(CommunityDenied):
            create_post(self.conn, actor_id="outsider", group_id="group1", title="X", body="Y")
        with self.assertRaises(CommunityDenied):
            create_comment(self.conn, actor_id="outsider", post_id=post, body="X")

    def test_only_author_or_moderator_can_delete(self):
        post = create_post(self.conn, actor_id="alice", group_id="group1", title="Title", body="Body")
        with self.assertRaises(CommunityDenied):
            delete_post(self.conn, actor_id="bob", post_id=post)
        delete_post(self.conn, actor_id="alice", post_id=post)
        self.assertEqual(list_posts(self.conn, actor_id="alice", group_id="group1"), [])

    def test_invalid_parent_comment_rejected(self):
        post = create_post(self.conn, actor_id="alice", group_id="group1", title="Title", body="Body")
        with self.assertRaises(ValueError):
            create_comment(self.conn, actor_id="bob", post_id=post, body="Hi", parent_id="missing")

if __name__ == "__main__":
    unittest.main()

"""Records commit-status POSTs the way the GitHub API would receive them."""
import http.server
import json
import sys

LOG = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a") as f:
            f.write("{} {} {} {} | {}\n".format(
                self.path, self.headers.get("Authorization"), body["state"],
                body["context"], body["description"]))
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", 9999), Handler).serve_forever()

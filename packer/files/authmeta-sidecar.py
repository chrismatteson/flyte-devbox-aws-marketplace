import http.server, os
from flyteidl2.auth.auth_service_pb2 import GetOAuth2MetadataResponse, GetPublicClientConfigResponse
ISSUER=os.environ["ISSUER"]; DOMAIN=os.environ["DOMAIN"]; CLIENT=os.environ["CLIENT"]
def meta():
    m=GetOAuth2MetadataResponse(issuer=ISSUER, authorization_endpoint=DOMAIN+"/oauth2/authorize",
        token_endpoint=DOMAIN+"/oauth2/token", jwks_uri=ISSUER+"/.well-known/jwks.json")
    m.response_types_supported.append("code"); m.scopes_supported.extend(["openid","profile"])
    m.code_challenge_methods_supported.append("S256")
    m.grant_types_supported.extend(["authorization_code","refresh_token"])
    return m
def pcc():
    return GetPublicClientConfigResponse(client_id=CLIENT, redirect_uri="http://localhost:8089/callback",
        scopes=["openid","profile"], authorization_metadata_key="authorization")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get("content-length",0)); self.rfile.read(n)
        if self.path.endswith("GetOAuth2Metadata"): b=meta().SerializeToString()
        elif self.path.endswith("GetPublicClientConfig"): b=pcc().SerializeToString()
        else: self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("content-type","application/proto"); self.send_header("content-length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",9099),H).serve_forever()

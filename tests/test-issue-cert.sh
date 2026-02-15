echo ""
echo "--- issue-cert.sh ---"

# T6: Issue a cert
run "$S/issue-cert.sh" test-a example.com "*.example.com"
assert_exit 0 $? "issue cert for test-a"
assert_file_exists "$SERVERS_DIR/test-a/server.key" "server.key created"
assert_file_exists "$SERVERS_DIR/test-a/server.crt" "server.crt created"
assert_file_exists "$SERVERS_DIR/test-a/server.csr" "server.csr created"
assert_file_exists "$SERVERS_DIR/test-a/san_server.cnf" "san_server.cnf created"

# T7: Cert has correct SANs
san_output=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -ext subjectAltName 2>&1 || true)
assert_contains "$san_output" "DNS:example.com" "cert has DNS:example.com"
assert_contains "$san_output" "DNS:*.example.com" "cert has DNS:*.example.com"

# T8: Cert chain validates
openssl verify -CAfile "$CA_DIR/ca.crt" "$SERVERS_DIR/test-a/server.crt" >/dev/null 2>&1
assert_exit 0 $? "cert chain validates"

# T9: Cert has correct DN
subject=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -subject 2>&1 || true)
assert_contains "$subject" "OU=Backoffice" "default OU is Backoffice"
assert_contains "$subject" "emailAddress=team@backoffice.oatmilk.work" "default email"

# T10: Custom --ou and --email
run "$S/issue-cert.sh" --ou Testing --email test@oatmilk.work test-b test.com
subject_b=$(openssl x509 -in "$SERVERS_DIR/test-b/server.crt" -noout -subject 2>&1 || true)
assert_contains "$subject_b" "OU=Testing" "custom --ou works"
assert_contains "$subject_b" "emailAddress=test@oatmilk.work" "custom --email works"

# T11: --forever gives long-lived cert
rm -rf "$SERVERS_DIR/test-b"
run "$S/issue-cert.sh" --forever test-b test.com
end_date=$(openssl x509 -in "$SERVERS_DIR/test-b/server.crt" -noout -enddate 2>&1 | sed 's/notAfter=//')
end_year=$(date -j -f "%b %d %T %Y %Z" "$end_date" "+%Y" 2>/dev/null || echo "0")
current_year=$(date "+%Y")
if (( end_year - current_year > 90 )); then
  pass "--forever gives 100-year cert"
else
  fail "--forever gives 100-year cert (expires $end_date)"
fi

# T12: --renew reuses existing key
old_key_hash=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
run "$S/issue-cert.sh" --renew test-a example.com "*.example.com"
new_key_hash=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
if [[ "$old_key_hash" == "$new_key_hash" ]]; then
  pass "--renew reuses existing key"
else
  fail "--renew reuses existing key (key changed)"
fi

# T13: Re-issue without --renew generates new key
old_key_hash2=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
run "$S/issue-cert.sh" test-a example.com
new_key_hash2=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
if [[ "$old_key_hash2" != "$new_key_hash2" ]]; then
  pass "re-issue generates new key"
else
  fail "re-issue generates new key (key unchanged)"
fi

echo ""
echo "--- issue-cert.sh error cases ---"

# T14: No args
output=$(run_output "$S/issue-cert.sh")
assert_contains "$output" "Missing arguments" "no args shows missing arguments"

# T15: Missing domain
output=$(run_output "$S/issue-cert.sh" myserver)
assert_contains "$output" "Missing domain" "missing domain error"

# T16: --renew on non-existent server
output=$(run_output "$S/issue-cert.sh" --renew ghost example.com)
assert_contains "$output" "no existing key" "renew non-existent server error"

# T17: Unknown flag
output=$(run_output "$S/issue-cert.sh" --bogus server example.com)
assert_contains "$output" "Unknown option" "unknown flag error"

# T18: --ou without value
output=$(run_output "$S/issue-cert.sh" --ou)
assert_contains "$output" "requires a value" "--ou without value error"

# T19: Issue cert without CA
rm -f "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"
output=$(run_output "$S/issue-cert.sh" test-a example.com)
assert_contains "$output" "CA not found" "issue without CA error"

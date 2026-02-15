echo ""
echo "--- rotate-ca.sh ---"

# Rebuild CA and servers for rotation test
run "$S/init-ca.sh"
run "$S/issue-cert.sh" --forever test-a example.com "*.example.com"
run "$S/issue-cert.sh" --ou DevOps test-b internal.oatmilk.work

old_ca_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
old_a_serial=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -serial 2>/dev/null)

# T20: Rotate regenerates everything
echo "y" | "$S/rotate-ca.sh" >/dev/null 2>&1
assert_exit 0 $? "rotate completes successfully"

new_ca_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
new_a_serial=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -serial 2>/dev/null)

if [[ "$old_ca_serial" != "$new_ca_serial" ]]; then
  pass "rotate regenerates CA"
else
  fail "rotate regenerates CA (serial unchanged)"
fi

if [[ "$old_a_serial" != "$new_a_serial" ]]; then
  pass "rotate re-issues server certs"
else
  fail "rotate re-issues server certs (serial unchanged)"
fi

# T21: Rotated certs still validate
openssl verify -CAfile "$CA_DIR/ca.crt" "$SERVERS_DIR/test-a/server.crt" >/dev/null 2>&1
assert_exit 0 $? "test-a validates after rotate"
openssl verify -CAfile "$CA_DIR/ca.crt" "$SERVERS_DIR/test-b/server.crt" >/dev/null 2>&1
assert_exit 0 $? "test-b validates after rotate"

# T22: Rotate preserves --forever
current_year=$(date "+%Y")
end_date=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -enddate 2>&1 | sed 's/notAfter=//')
end_year=$(date -j -f "%b %d %T %Y %Z" "$end_date" "+%Y" 2>/dev/null || echo "0")
if (( end_year - current_year > 90 )); then
  pass "rotate preserves --forever on test-a"
else
  fail "rotate preserves --forever on test-a (expires $end_date)"
fi

# T23: Rotate preserves custom OU
subject_b=$(openssl x509 -in "$SERVERS_DIR/test-b/server.crt" -noout -subject 2>&1 || true)
assert_contains "$subject_b" "OU=DevOps" "rotate preserves custom OU on test-b"

# T24: Decline rotation
old_ca_serial2=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
echo "n" | "$S/rotate-ca.sh" >/dev/null 2>&1
new_ca_serial2=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
if [[ "$old_ca_serial2" == "$new_ca_serial2" ]]; then
  pass "declining rotation changes nothing"
else
  fail "declining rotation changes nothing (CA serial changed)"
fi

echo "--- init-ca.sh ---"

# T1: Init CA from scratch
run "$S/init-ca.sh"
assert_exit 0 $? "init CA from scratch"
assert_file_exists "$CA_DIR/ca.key" "ca.key created"
assert_file_exists "$CA_DIR/ca.crt" "ca.crt created"

# T2: CA has correct extensions
ca_text=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -text 2>&1 || true)
assert_contains "$ca_text" "CA:TRUE" "CA cert has basicConstraints CA:TRUE"
assert_contains "$ca_text" "Certificate Sign" "CA cert has keyCertSign"

# T3: Refuse to overwrite without --force
output=$(run_output "$S/init-ca.sh")
assert_contains "$output" "CA already exists" "overwrite error shows CA exists"
assert_contains "$output" "--force" "overwrite error suggests --force"

# T4: --force regenerates
old_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
run "$S/init-ca.sh" --force
new_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
if [[ "$old_serial" != "$new_serial" ]]; then
  pass "--force regenerates CA (new serial)"
else
  fail "--force regenerates CA (serial unchanged)"
fi

# T5: Init generates san_ca.cnf if missing
rm -f "$CA_DIR/san_ca.cnf" "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"
run "$S/init-ca.sh"
assert_exit 0 $? "init-ca.sh generates san_ca.cnf if missing"
assert_file_exists "$CA_DIR/san_ca.cnf" "san_ca.cnf auto-generated"
assert_file_exists "$CA_DIR/ca.crt" "ca.crt created after auto-generate"

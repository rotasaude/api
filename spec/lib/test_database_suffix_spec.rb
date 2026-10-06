# Unidade pura — sem Rails e sem banco (só spec_helper): o nome dos bancos de
# cidade de teste sem ROTA_TEST_DB_SUFFIX é idêntico ao de antes da variável.
require_relative "../../lib/test_database_suffix"

RSpec.describe TestDatabaseSuffix do
  it "is empty, and leaves names unchanged, when the variable is unset or empty" do
    [ {}, { "ROTA_TEST_DB_SUFFIX" => "" } ].each do |env|
      expect(described_class.value(env)).to eq("")
      expect(described_class.apply("rota_saude_test_city_a", env)).to eq("rota_saude_test_city_a")
      expect(described_class.apply("rota_saude_test_city_b", env)).to eq("rota_saude_test_city_b")
    end
  end

  it "appends a valid suffix to the name" do
    env = { "ROTA_TEST_DB_SUFFIX" => "_mod17" }

    expect(described_class.value(env)).to eq("_mod17")
    expect(described_class.apply("rota_saude_test_city_a", env)).to eq("rota_saude_test_city_a_mod17")
  end

  it "refuses a suffix outside [a-z0-9_] with a message naming the variable" do
    [ "Bad-1", "_x;drop", " _a", "_a\n", "é" ].each do |bad|
      expect { described_class.value({ "ROTA_TEST_DB_SUFFIX" => bad }) }
        .to raise_error(TestDatabaseSuffix::Invalid, /ROTA_TEST_DB_SUFFIX.*\[a-z0-9_\]/)
    end
  end
end

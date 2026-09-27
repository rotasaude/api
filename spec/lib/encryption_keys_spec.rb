require "rails_helper"

# F-06.12: custódia das chaves do AR Encryption (ADR-0013). O deploy injeta
# ACTIVE_RECORD_ENCRYPTION_*; o initializer só lia AR_ENCRYPTION_*, então em
# produção as chaves do cofre nunca chegavam. Ambiente publicado sem as três
# chaves não sobe.
RSpec.describe EncryptionKeys do
  let(:full_creds) do
    { active_record_encryption: { primary_key: "cred-p", deterministic_key: "cred-d", key_derivation_salt: "cred-s" } }
  end
  let(:deploy_env) do
    { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "env-p",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "env-d",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "env-s" }
  end
  let(:legacy_env) do
    { "AR_ENCRYPTION_PRIMARY_KEY" => "old-p",
      "AR_ENCRYPTION_DETERMINISTIC_KEY" => "old-d",
      "AR_ENCRYPTION_KEY_DERIVATION_SALT" => "old-s" }
  end

  def resolve(credentials: {}, env: {}, deployed: false)
    described_class.resolve(credentials: credentials, env: env, deployed: deployed)
  end

  it "credentials vencem as variáveis de ambiente" do
    expect(resolve(credentials: full_creds, env: deploy_env.merge(legacy_env)))
      .to eq(primary_key: "cred-p", deterministic_key: "cred-d", key_derivation_salt: "cred-s")
  end

  it "sem credentials, lê as ACTIVE_RECORD_ENCRYPTION_* que o deploy injeta" do
    expect(resolve(env: deploy_env.merge(legacy_env), deployed: true))
      .to eq(primary_key: "env-p", deterministic_key: "env-d", key_derivation_salt: "env-s")
  end

  it "cai nas AR_ENCRYPTION_* legadas por último, chave a chave" do
    env = legacy_env.merge("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "env-p")
    expect(resolve(env: env))
      .to eq(primary_key: "env-p", deterministic_key: "old-d", key_derivation_salt: "old-s")
  end

  it "trata string vazia como ausente" do
    expect(resolve(env: deploy_env.merge("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => ""), deployed: false)[:primary_key])
      .to be_nil
  end

  it "ambiente publicado sem alguma das três chaves derruba o boot, nomeando a que falta" do
    env = deploy_env.except("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")

    expect { resolve(env: env, deployed: true) }
      .to raise_error(EncryptionKeys::Missing, /ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY/)
  end

  it "a mensagem de erro nunca carrega o valor de uma chave" do
    env = deploy_env.except("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")

    expect { resolve(env: env, deployed: true) }
      .to raise_error(EncryptionKeys::Missing) { |e| expect(e.message).not_to include("env-p", "env-d") }
  end

  it "em dev/test, chave ausente fica nil sem erro" do
    expect(resolve).to eq(primary_key: nil, deterministic_key: nil, key_derivation_salt: nil)
  end

  it "o initializer aplica a resolução à configuração do Rails" do
    config = Rails.application.config.active_record.encryption
    resolved = described_class.resolve(credentials: Rails.application.credentials, env: ENV, deployed: false)

    expect(config.primary_key).to eq(resolved[:primary_key])
    expect(config.deterministic_key).to eq(resolved[:deterministic_key])
    expect(config.key_derivation_salt).to eq(resolved[:key_derivation_salt])
  end
end

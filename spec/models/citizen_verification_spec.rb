require "rails_helper"

RSpec.describe CitizenVerification do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:admin) { User.create!(email_address: "admin@cidade.gov.br", password: "senha-segura-123") }

  def verification
    described_class.create!(citizen: citizen, verified_by_user: verifier, verified_at: Time.current)
  end

  it "permite uma validação ativa por cidadão" do
    verification
    expect { verification }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "desfaz uma vez, com os três campos juntos" do
    v = verification
    v.update!(revoked_at: Time.current, revoked_by_user: admin, revoke_reason: "documento de outra pessoa")
    expect(v.reload).not_to be_active
    expect { v.update!(revoke_reason: "outro motivo qualquer") }.to raise_error(ActiveRecord::StatementInvalid, /already revoked/)
  end

  it "depois de desfeita, aceita uma validação nova" do
    verification.update!(revoked_at: Time.current, revoked_by_user: admin, revoke_reason: "documento de outra pessoa")
    expect { verification }.not_to raise_error
  end

  it "recusa motivo curto e revogação incompleta" do
    v = verification
    expect { v.update!(revoked_at: Time.current, revoked_by_user: admin, revoke_reason: "curto") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_citizen_verifications_revocation/)
    expect { v.reload.update!(revoked_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_citizen_verifications_revocation/)
  end

  # .delete e .update_column falam SQL bruto, sem abrir transação própria (ao
  # contrário de .create!/.update!, que abrem uma — e por isso já viram
  # savepoint dentro da transação de fixture do teste). Sem
  # requires_new: true aqui, a exceção do primeiro trigger deixaria a conexão
  # em "current transaction is aborted" para a segunda tentativa (mesmo padrão
  # de spec/models/protocol_append_only_spec.rb#attempt).
  it "recusa apagar e recusa mudar quem validou" do
    v = verification
    expect { CitizenVerification.transaction(requires_new: true) { v.delete } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { CitizenVerification.transaction(requires_new: true) { v.update_column(:verified_by_user_id, admin.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /only the revocation columns/)
  end
end

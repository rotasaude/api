require "rails_helper"

RSpec.describe CitizenErasureRequest do
  before { Current.city = TEST_CITY_A }

  def attempt = ApplicationRecord.transaction(requires_new: true) { yield }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { User.create!(email_address: "v-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let(:admin) { User.create!(email_address: "a-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:request) do
    described_class.create!(cpf: citizen.cpf, presented_citizen: citizen, requested_by_user: verifier,
                            document_checked: true, status: "pending")
  end

  it "recusa DELETE" do
    expect { attempt { described_class.where(id: request.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /citizen_erasure_requests is append-only/)
  end

  it "aceita uma decisão e recusa a segunda" do
    request.update_columns(status: "rejected", decided_by_user_id: admin.id, decided_at: Time.current,
                           reject_reason: "documento não confere")
    expect { attempt { request.update_columns(status: "confirmed") } }
      .to raise_error(ActiveRecord::StatementInvalid, /already decided/)
  end

  it "recusa mudar quem pediu ou o par apresentado" do
    expect { attempt { request.update_columns(requested_by_user_id: admin.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /only the decision columns/)
  end

  it "recusa trocar o cpf fora da confirmação e aceita na confirmação" do
    expect { attempt { request.update_columns(cpf: "outro") } }
      .to raise_error(ActiveRecord::StatementInvalid, /only the decision columns/)
    request.update_columns(cpf: "marcador", status: "confirmed", decided_by_user_id: admin.id, decided_at: Time.current)
    expect(request.reload.status).to eq("confirmed")
  end

  it "aceita trocar o cpf na recusa; recusa na retenção" do
    request.update_columns(cpf: "marcador", status: "rejected", decided_by_user_id: admin.id, decided_at: Time.current,
                           reject_reason: "documento não confere")
    expect(request.reload.status).to eq("rejected")

    other = Citizen.create!(cpf: "11144477735", phone: "+5541998765433")
    pending = described_class.create!(cpf: other.cpf, presented_citizen: other, requested_by_user: verifier,
                                      document_checked: true, status: "pending")
    expect { attempt { pending.update_columns(cpf: "marcador", status: "retained", decided_at: Time.current) } }
      .to raise_error(ActiveRecord::StatementInvalid, /only the decision columns/)
  end

  it "numa linha decidida aceita só a mudança do cpf (re-cifra) e recusa o resto" do
    request.update_columns(status: "rejected", cpf: "marcador", decided_by_user_id: admin.id, decided_at: Time.current,
                           reject_reason: "documento não confere")
    request.update_columns(cpf: "outro-marcador")
    expect(request.reload.cpf).to eq("outro-marcador")

    {
      status: "confirmed", decided_by_user_id: verifier.id, decided_at: 1.day.ago, reject_reason: "outro motivo qualquer",
      requested_by_user_id: admin.id, presented_citizen_id: Citizen.create!(cpf: "11144477735", phone: "+5541998765433").id
    }.each do |column, value|
      expect { attempt { request.update_columns(column => value) } }
        .to raise_error(ActiveRecord::StatementInvalid, /already decided/), "#{column} mudou"
    end
  end

  it "exige documento conferido e decisão coerente com o status" do
    expect { attempt { described_class.create!(cpf: "x", presented_citizen: citizen, requested_by_user: verifier, document_checked: false, status: "pending") } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_citizen_erasure_requests_document/)
  end

  it "aceita retained já decidido, sem decisor" do
    other = Citizen.create!(cpf: "11144477735", phone: "+5541998765433")
    r = described_class.create!(cpf: other.cpf, presented_citizen: other, requested_by_user: verifier,
                                document_checked: true, status: "retained", decided_at: Time.current)
    expect(r.decided_by_user_id).to be_nil
  end

  it "recusa um segundo pedido pendente para o mesmo CPF" do
    expect { attempt { described_class.create!(cpf: citizen.cpf, presented_citizen: citizen, requested_by_user: verifier, document_checked: true, status: "pending") } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_citizen_erasure_requests_one_pending/)
  end

  it "Citizen.not_erased exclui quem tem erased_at" do
    expect(Citizen.not_erased).to include(citizen)
    citizen.update_columns(erased_at: Time.current)
    expect(Citizen.not_erased).not_to include(citizen)
  end

  it "guarda o CPF cifrado" do
    raw = described_class.connection.select_value(described_class.sanitize_sql(["SELECT cpf FROM citizen_erasure_requests WHERE id = ?", request.id]))
    expect(raw).not_to include("52998224725")
    expect(described_class.where(cpf: "52998224725").pluck(:id)).to eq([request.id])
  end
end

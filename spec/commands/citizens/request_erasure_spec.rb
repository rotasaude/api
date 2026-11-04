require "rails_helper"

RSpec.describe Citizens::RequestErasure do
  before { Current.city = TEST_CITY_A }

  let(:verifier) { User.create!(email_address: "v-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:pair_a) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let!(:pair_b) { Citizen.create!(cpf: "52998224725", phone: "+5541998760000") }

  def request!(cpf: "529.982.247-25", checked: true) = described_class.call(cpf: cpf, document_checked: checked, by: verifier)

  it "cria pedido pendente para o CPF, apresentando um par" do
    result = request!
    expect(result.payload[:request]).to have_attributes(status: "pending", requested_by_user_id: verifier.id)
    expect(DomainEvent.where(name: "citizen.erasure_requested").order(:occurred_at, :created_at).last.payload.keys).to contain_exactly("request_id")
  end

  it "nasce retido quando algum par do CPF tem atendimento" do
    triage = completed_web_triage_for(pair_b)
    Attendance.create!(triage: triage, citizen: pair_b, health_unit: create_unit, checked_in_by_user: verifier,
                       checked_in_at: Time.current, check_in_method: "code")
    expect(request!.payload[:request]).to have_attributes(status: "retained", decided_at: be_present)
    expect(DomainEvent.where(name: "citizen.erasure_retained").order(:occurred_at, :created_at).last.payload.keys).to contain_exactly("request_id")
  end

  it "recusa sem documento conferido, CPF inválido, CPF sem cadastro e pedido já pendente" do
    expect(request!(checked: false).reason).to eq(:document_check_required)
    expect(request!(cpf: "123").reason).to eq(:invalid_cpf)
    expect(request!(cpf: "111.444.777-35").reason).to eq(:citizen_not_found)
    request!
    expect(request!.reason).to eq(:already_pending)
  end

  # ADR 0048 (módulo 30, Desvio 17): o processo de TFD entra na regra única de
  # retenção; o caminho completo está em erase_transport_spec.rb.
  it "examined_patients? consulta o processo de TFD (tfd_cased?)" do
    ids = [ SecureRandom.uuid ]
    expect(described_class.tfd_cased?(ids)).to be(false)
    expect(described_class.examined_patients?(ids)).to be(false)
    allow(described_class).to receive(:tfd_cased?).with(ids).and_return(true)
    expect(described_class.examined_patients?(ids)).to be(true)
  end

  # ADR 0049 (módulo 31; contrato §14, P17): o registro do CAPS entra na regra
  # única de retenção; o caminho completo está em erase_psychosocial_spec.rb.
  it "examined_patients? consulta o registro do CAPS (psychosocial_recorded?)" do
    ids = [ SecureRandom.uuid ]
    expect(described_class.psychosocial_recorded?(ids)).to be(false)
    expect(described_class.examined_patients?(ids)).to be(false)
    allow(described_class).to receive(:psychosocial_recorded?).with(ids).and_return(true)
    expect(described_class.examined_patients?(ids)).to be(true)
  end
end

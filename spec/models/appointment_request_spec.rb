require "rails_helper"

RSpec.describe AppointmentRequest do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:origin) do
    in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor).tap do |a|
      a.update!(status: "closed", outcome: "return", closed_by_user: doctor, closed_at: Time.current)
    end
  end

  it "retorno exige destino igual à origem" do
    expect { request_for(origin, kind: "return", target: other_unit) }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "encaminhamento aceita a própria unidade ou outra" do
    expect { request_for(origin, kind: "referral", target: unit) }.not_to raise_error
  end

  it "um pedido por atendimento de origem" do
    request_for(origin)
    expect { request_for(origin) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "encerrar como dismissed exige justificativa de 10+" do
    req = request_for(origin)
    expect { req.update!(status: "closed", closed_reason: "dismissed", dismiss_reason: "curto", closed_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid)
  end

  it "pedido encerrado não muda e origem nunca muda" do
    req = request_for(origin)
    expect do
      AppointmentRequest.transaction(requires_new: true) { AppointmentRequest.where(id: req.id).update_all(kind: "referral") }
    end.to raise_error(ActiveRecord::StatementInvalid, /origin columns never change/)
    req.update!(status: "closed", closed_reason: "citizen_cancelled", closed_at: Time.current)
    expect { req.update!(status: "open") }.to raise_error(ActiveRecord::StatementInvalid, /already closed/)
    expect { req.destroy }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
  end
end

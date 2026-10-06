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
  # ADR 0029 + ADR 0026 (pré-merge PM-B item 3): a exclusão LGPD apaga o texto
  # livre do remarque também do pedido encerrado — só isso, mais nada.
  describe "pedido encerrado: só a nota do remarque pode ir a NULL" do
    def closed_with_note
      req = request_for(origin)
      req.update!(reschedule_note: "Trabalho no turno da manhã", reschedule_reason_code: "work",
                  preferred_period: "afternoon")
      req.update!(status: "closed", closed_reason: "citizen_cancelled", closed_at: Time.current)
      req
    end

    def raw_update(req, **attrs)
      AppointmentRequest.transaction(requires_new: true) { AppointmentRequest.where(id: req.id).update_all(attrs) }
    end

    it "anular a nota passa" do
      req = closed_with_note
      expect { raw_update(req, reschedule_note: nil) }.not_to raise_error
      expect(req.reload.reschedule_note).to be_nil
      expect(req).to have_attributes(status: "closed", reschedule_reason_code: "work", preferred_period: "afternoon")
    end

    it "trocar a nota por outro texto continua recusado" do
      req = closed_with_note
      expect { raw_update(req, reschedule_note: "outro texto qualquer") }
        .to raise_error(ActiveRecord::StatementInvalid, /already closed/)
    end

    it "qualquer outra coluna continua recusada" do
      req = closed_with_note
      { status: "open", due_on: Time.zone.today + 90, priority: "priority", reschedule_reason_code: "health",
        preferred_period: "morning", reschedule_count: 3, closed_reason: "dismissed",
        updated_at: 1.day.from_now }.each do |column, value|
        expect { raw_update(req, column => value) }
          .to raise_error(ActiveRecord::StatementInvalid, /already closed/), "#{column} passou"
      end
    end

    it "anular a nota junto com outra coluna é recusado" do
      req = closed_with_note
      expect { raw_update(req, reschedule_note: nil, priority: "priority") }
        .to raise_error(ActiveRecord::StatementInvalid, /already closed/)
      expect { raw_update(req, reschedule_note: nil, updated_at: Time.current + 1) }
        .to raise_error(ActiveRecord::StatementInvalid, /already closed/)
    end
  end
end

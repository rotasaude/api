require "rails_helper"

# Módulo 26a (ADR 0044): o banco da regulação. O pedido é o estado atual com
# `version`; o andamento e as autorizações são linhas próprias; os CHECKs e os
# triggers (db/city_triggers.sql) seguram o que o código não pode quebrar.
RSpec.describe "Esquema da regulação (ADR 0044)" do
  before { regulation_city! }
  let(:doctor_unit) { HealthUnit.create!(name: "UBS Regula #{SecureRandom.hex(2)}", kind: "ubs") }
  let(:doctor) { doctor!(doctor_unit) }
  let(:citizen) { verified_citizen!(7) }
  let(:consultation) { started_consultation!(unit: doctor_unit, doctor: doctor, citizen: citizen) }

  def row(**over)
    RegulationRequest.create!({ patient: consultation.patient, consultation: consultation, requester_user: doctor, requester_cbo: "225125",
                                requester_unit: doctor_unit, target_type: "specialty", target_code: "225120",
                                target_name: "Médico cardiologista", cid10: "I10", justification: "Hipertensão resistente a três fármacos",
                                suggested_color: "yellow", status: "draft" }.merge(over))
  end

  # Escrita crua (delete, update_columns, SQL) que o banco recusa: sem savepoint,
  # a recusa aborta a transação do exemplo e o resto falha com
  # InFailedSqlTransaction (o create! já roda no savepoint dele).
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "rascunho sem data; fora do rascunho, com data e prazo" do
    expect { row(requested_at: Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /ck_regulation_requests/)
    expect { row(status: "pending") }.to raise_error(ActiveRecord::StatementInvalid, /ck_regulation_requests/)
    expect { row(status: "pending", requested_at: Time.current, due_on: Date.current + 30) }.not_to raise_error
  end

  it "triggers: rascunho se apaga, pedido não; alvo e paciente imutáveis; encerrado não volta" do
    draft = row
    expect { draft.delete }.not_to raise_error
    live = row(status: "pending", requested_at: Time.current, due_on: Date.current + 30)
    refused(/only a draft is deleted/) { live.delete }
    refused(/never change/) { live.update_columns(target_code: "225265") }
    refused(/never change/) { live.update_columns(patient_id: regulation_patient!(exam_seq!).first.id) }
    # A autoria do pedido enviado (usuário, CBO e unidade) também nunca muda.
    refused(/never change/) { live.update_columns(requester_user_id: care_regulator!.id) }
    refused(/never change/) { live.update_columns(requester_cbo: "223505") }
    refused(/never change/) { live.update_columns(requester_unit_id: HealthUnit.create!(name: "UBS Outra #{SecureRandom.hex(2)}", kind: "ubs").id) }
    # O diagnóstico muda fora do rascunho (complemento).
    expect { live.update!(cid10: "E119", ciap2: "K86") }.not_to raise_error
    live.update!(status: "denied")
    refused(/never changes status/) { live.update_columns(status: "pending") }
  end

  it "autorização: libera uma vez; nunca some; oferta e prestador nunca somem" do
    provider = external_provider!
    offer = offer!(provider: provider)
    req = row(status: "authorized", requested_at: Time.current, due_on: Date.current + 30)
    auth = RegulationAuthorization.create!(regulation_request: req, care_offer: offer, month: offer.month, authorized_by_user: care_regulator!)
    auth.update!(released_at: Time.current, release_reason: "cancelled")
    refused(/already released/) { auth.update_columns(released_at: nil, release_reason: nil) }
    refused(/only released_at and release_reason change/) { auth.update_columns(month: offer.month.next_month) }
    refused(/DELETE refused/) { auth.delete }
    refused(/DELETE refused/) { offer.delete }
    refused(/DELETE refused/) { provider.delete }
    refused(/DELETE refused/) { RegulationRiskDeadline.find("red").delete }
    # Com quem gravou (NOT NULL), para quem recusa ser o CHECK do CNES.
    expect { CareProvider.create!(name: "Sem CNES", kind: "contracted", updated_by_user: regulation_admin!) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_care_providers_cnes_required/)
    expect { offer!(provider: provider) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_care_offers_unique/)
  end

  it "pedido de agendamento regulated: origem única, sem raiz, um vivo por pedido de regulação" do
    req = row(status: "authorized", requested_at: Time.current, due_on: Date.current + 30)
    attrs = { kind: "regulated", origin_regulation_request_id: req.id, citizen: citizen, origin_unit: doctor_unit, target_unit: doctor_unit,
              appointment_type_key: "consulta_medica", priority: "routine", due_on: Date.current + 30 }
    AppointmentRequest.create!(attrs)
    expect { AppointmentRequest.create!(attrs) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_appointment_requests_one_live_regulated/)
    expect { AppointmentRequest.create!(attrs.merge(kind: "referral")) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(AppointmentRequest.new(origin_regulation_request_id: req.id).origin).to eq("regulation")
  end

  it "papel care_regulator aceito e privilegiado; prazos padrão; nada pessoal no inspect" do
    expect { care_regulator! }.not_to raise_error
    expect(Membership::PRIVILEGED_ROLES).to include("care_regulator")
    expect(RegulationRiskDeadline.order(:color).pluck(:color, :days)).to eq([ [ "blue", 180 ], [ "green", 90 ], [ "red", 7 ], [ "yellow", 30 ] ])
    expect(row(ciap2: "K86").inspect).not_to include("Hipertensão", "I10", "225120", "K86")
  end

  it "andamento só acréscimo; TRUNCATE recusado nas seis; a lista do enfermeiro sai e volta" do
    live = row(status: "pending", requested_at: Time.current, due_on: Date.current + 30)
    event = RegulationRequestEvent.create!(regulation_request: live, status: "pending", reason: "Pedido enviado à regulação")
    refused(/append-only/) { event.update_columns(status: "denied") }
    refused(/append-only/) { event.delete }
    refused(/ck_regulation_request_events_status/) { RegulationRequestEvent.create!(regulation_request: live, status: "draft") }
    item = NurseRequestableItem.create!(target_type: "specialty", target_code: "225250", created_by_user: regulation_admin!)
    expect { item.delete }.not_to raise_error
    %w[regulation_requests regulation_request_events regulation_authorizations care_providers care_offers
       regulation_risk_deadlines].each do |table|
      refused(/append-only/) { ApplicationRecord.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end

  it "a re-cifra regrava só o texto cifrado: autorização e andamento passam; outra coluna continua recusada" do
    offer = offer!(provider: external_provider!)
    req = row(status: "authorized", requested_at: Time.current, due_on: Date.current + 30, color_reason: "Piora do quadro")
    auth = RegulationAuthorization.create!(regulation_request: req, care_offer: offer, month: offer.month, skip_reason: "Caso mais grave",
                                           authorized_by_user: care_regulator!)
    event = RegulationRequestEvent.create!(regulation_request: req, status: "authorized", reason: "Vaga na cardiologia")
    expect { CityEncryption.allowing_reencryption { req.encrypt; auth.encrypt; event.encrypt } }.not_to raise_error
    expect(auth.reload.skip_reason).to eq("Caso mais grave")
    expect(event.reload.reason).to eq("Vaga na cardiologia")
    refused(/only released_at and release_reason change/) do
      CityEncryption.allowing_reencryption { auth.update_columns(skip_reason: "outro", month: offer.month.next_month) }
    end
    expect(CityEncryption::CITY_KEYED_TARGETS).to include(
      [ RegulationRequest, :cid10 ], [ RegulationRequest, :ciap2 ], [ RegulationRequest, :justification ],
      [ RegulationRequest, :color_reason ], [ RegulationRequest, :schedule_notes ],
      [ RegulationRequestEvent, :reason ], [ RegulationAuthorization, :skip_reason ]
    )
  end

  it "diagnóstico: cid10 e ciap2 opcionais no banco (a regra é do serviço)" do
    r = row(cid10: nil, ciap2: "K86")
    expect(r.reload).to have_attributes(cid10: nil, ciap2: "K86")
    stored = RegulationRequest.connection.select_value("SELECT ciap2 FROM regulation_requests WHERE id = '#{r.id}'")
    expect(stored).to be_present
    expect(stored).not_to include("K86")
  end
end

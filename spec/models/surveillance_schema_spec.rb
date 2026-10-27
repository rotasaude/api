require "rails_helper"

RSpec.describe "Esquema da vigilância (ADR 0043)" do
  before { surveillance_city! }
  let(:patient) { surveillance_patient!(1) }
  let(:unit) { HealthUnit.create!(name: "UBS Vigia #{SecureRandom.hex(2)}", kind: "ubs") }

  def row(**over)
    DiseaseNotification.create!({ patient: patient, disease_code: "dengue", disease_list_version: 1, deadline: "weekly", origin: "manual",
                                  status: "notified", suspected_on: Date.current, due_at: 7.days.from_now, health_unit: unit,
                                  form: {} }.merge(over))
  end

  # Escrita crua (delete, update_columns, SQL) que o banco recusa: sem savepoint,
  # a recusa aborta a transação do exemplo e o resto falha com
  # InFailedSqlTransaction.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "uma aberta por paciente e doença; fechada não conta" do
    first = row
    expect { row }.to raise_error(ActiveRecord::RecordNotUnique, /idx_disease_notifications_one_open/)
    first.update!(status: "closed", classification: "discarded", closed_at: Time.current)
    expect { row }.not_to raise_error
  end

  it "CHECKs: classificação só fechada; número oficial só digitada; IBGE com residente fora" do
    expect { row(status: "investigating", classification: "confirmed") }.to raise_error(ActiveRecord::StatementInvalid, /ck_disease_notifications/)
    expect { row(official_number: "1234567") }.to raise_error(ActiveRecord::StatementInvalid)
    expect { row(resident_elsewhere: true) }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "CHECKs: sintomas depois da suspeita, IBGE malformado e semana mal escrita são recusados" do
    expect { row(symptoms_on: Date.current + 1) }.to raise_error(ActiveRecord::StatementInvalid, /ck_disease_notifications/)
    expect { row(resident_elsewhere: true, residence_ibge: "41069") }.to raise_error(ActiveRecord::StatementInvalid, /ck_disease_notifications/)
    expect { row(resident_elsewhere: false, residence_ibge: "4106902") }.to raise_error(ActiveRecord::StatementInvalid, /ck_disease_notifications/)
    expect { row(resident_elsewhere: true, residence_ibge: "4106902") }.not_to raise_error
    expect { WeeklyNegativeReport.create!(health_unit: unit, week: "2026-4", recorded_by_user_id: surveillance_officer!.id) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_weekly_negative_reports/)
  end

  it "triggers: sem DELETE, paciente imutável, digitada não volta, andamento só acréscimo, negativa imutável" do
    n = row
    refused(/DELETE refused/) { n.delete }
    other = surveillance_patient!(2)
    refused(/never change/) { n.update_columns(patient_id: other.id) }
    n.update!(status: "closed", classification: "confirmed", closed_at: Time.current)
    n.update!(status: "entered", official_number: "1234567", entered_at: Time.current)
    refused(/never changes status/) { n.update_columns(status: "closed", official_number: nil) }
    event = DiseaseNotificationEvent.create!(notification_id: n.id, status: "entered", by_user_id: nil, reason: "x")
    refused(/append-only/) { event.update_columns(status: "closed") }
    neg = WeeklyNegativeReport.create!(health_unit: unit, week: "2026-42", recorded_by_user_id: surveillance_officer!.id)
    refused(/append-only/) { neg.delete }
  end

  it "descartada não volta; a lista local não perde linha; TRUNCATE recusado nas quatro" do
    n = row
    n.update!(status: "dismissed", dismissed_at: Time.current)
    refused(/never changes status/) { n.update_columns(status: "notified") }
    local = LocalNotifiableDisease.create!(code: "local_teste_pr", name: "Agravo local", deadline: "weekly", cid10: [], ciap2: [],
                                           repeat_after_days: 30, updated_by_user: surveillance_officer!)
    refused(/DELETE refused/) { local.delete }
    refused(/ck_local_notifiable_diseases/) { local.update!(code: "teste") }
    %w[disease_notifications disease_notification_events weekly_negative_reports local_notifiable_diseases].each do |table|
      refused(/append-only/) { ApplicationRecord.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end

  it "o texto livre do andamento e a ficha são cifrados com a chave da cidade" do
    n = row(form: { "pregnancy" => "5" })
    event = DiseaseNotificationEvent.create!(notification_id: n.id, status: "notified", reason: "contato com caso")
    raw = ApplicationRecord.connection.select_one("SELECT form FROM disease_notifications WHERE id = '#{n.id}'")["form"]
    raw_reason = ApplicationRecord.connection.select_one("SELECT reason FROM disease_notification_events WHERE id = '#{event.id}'")["reason"]
    expect(raw).not_to include("pregnancy")
    expect(raw_reason).not_to include("contato")
    expect(n.reload.form).to eq("pregnancy" => "5")
    expect(event.reload.reason).to eq("contato com caso")
    expect(CityEncryption::CITY_KEYED_TARGETS).to include([ DiseaseNotification, :form ], [ DiseaseNotificationEvent, :reason ])
  end

  it "a re-cifra regrava só o texto cifrado: a ficha e o motivo passam; outra coluna do andamento continua recusada" do
    n = row(form: { "pregnancy" => "5" })
    event = DiseaseNotificationEvent.create!(notification_id: n.id, status: "notified", reason: "x")
    expect { CityEncryption.allowing_reencryption { n.encrypt; event.encrypt } }.not_to raise_error
    expect(n.reload.form).to eq("pregnancy" => "5")
    expect(event.reload.reason).to eq("x")
    refused(/append-only/) { CityEncryption.allowing_reencryption { event.update_columns(reason: "y", status: "closed") } }
  end

  it "papel surveillance aceito pelo banco e privilegiado; unidade de APS ativa nasce notificadora" do
    expect { surveillance_officer! }.not_to raise_error
    expect(Membership::PRIVILEGED_ROLES).to include("surveillance")
    expect(HealthUnit.create!(name: "UBS Nova #{SecureRandom.hex(2)}", kind: "ubs").notifying).to be(true)
    expect(HealthUnit.create!(name: "UPA Nova #{SecureRandom.hex(2)}", kind: "upa").notifying).to be(false)
    expect(HealthUnit.create!(name: "UBS Fora #{SecureRandom.hex(2)}", kind: "ubs", notifying: false).notifying).to be(false)
    expect(HealthUnit.create!(name: "UPA Dentro #{SecureRandom.hex(2)}", kind: "upa", notifying: true).notifying).to be(true)
  end

  # R18: dado pessoal nunca sai por inspect, to_s, pretty_print nem as_json.
  it "R18: a notificação e o andamento não vazam dado pessoal em inspect, to_s, pretty_print nem as_json" do
    n = DiseaseNotification.new(form: { "pregnancy" => "5" }, symptoms_on: Date.new(2026, 10, 1), official_number: "NUM-998877",
                                residence_ibge: "4106902", status: "notified", disease_code: "dengue")
    event = DiseaseNotificationEvent.new(reason: "paciente relatou segredo-clinico", status: "notified")
    [ n, event ].each do |record|
      rendered = [ record.inspect, record.to_s, PP.pp(record, +""), record.as_json.to_s, record.to_json ].join(" ")
      %w[pregnancy NUM-998877 4106902 2026-10-01 segredo-clinico dengue].each { |secret| expect(rendered).not_to include(secret) }
    end
    expect(n.inspect).to include("status=notified")
  end
end

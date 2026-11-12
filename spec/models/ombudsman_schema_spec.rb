require "rails_helper"
require Rails.root.join("db/city_migrate/20261111900002_add_ombudsman.rb").to_s

# Módulo 33 (ADR 0051): o banco da ouvidoria. Protocolo sequencial com o ano
# local, colunas do registro imutáveis (citizen_id só vai a nulo, com os
# manifestant_* juntos — U1), anônima só denúncia e sem pessoa, linha do tempo,
# acessos e satisfação só acréscimo, encaminhamento com extrato imutável e
# resposta uma vez, anexo órfão em cascata com o arquivo, re-cifra antes de
# tudo, assuntos em dois níveis e nada de texto em inspect/as_json.
RSpec.describe "Esquema da ouvidoria (ADR 0051)", type: :model do
  include ActiveSupport::Testing::TimeHelpers

  before { ombudsman_city! }

  # Escrita crua (delete, update_columns, SQL) que o banco recusa: sem savepoint,
  # a recusa aborta a transação do exemplo (o create!/update! já roda no dele).
  # O update_columns recusado deixa o valor novo no objeto: recarregue antes de
  # um update! que dependa do sujo.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  def forwarding!(manifestation, destination: department!)
    key = destination.is_a?(Department) ? :department : :health_unit
    OmbudsmanForwarding.create!(ombudsman_manifestation: manifestation, key => destination, extract: "Extrato do caso para o setor responder.",
                                due_on: Date.current + 20, state: "pending", created_by_user: ombudsman_staff!)
  end

  it "a migração espelha o catálogo, as listas dos modelos e a semente de assuntos" do
    catalog = Ombudsman::Catalog
    expect([ AddOmbudsman::KINDS, AddOmbudsman::MODES, AddOmbudsman::CHANNELS, AddOmbudsman::STATES, AddOmbudsman::RESOLUTIONS,
             AddOmbudsman::ARCHIVE_REASONS, AddOmbudsman::FORWARDING_STATES, AddOmbudsman::EVENT_KINDS, AddOmbudsman::NOTICE_KINDS,
             AddOmbudsman::MET ])
      .to eq([ catalog::KINDS, catalog::MODES, catalog::CHANNELS, catalog::STATES, catalog::RESOLUTIONS, catalog::ARCHIVE_REASONS,
               catalog::FORWARDING_STATES, catalog::EVENT_KINDS, catalog::NOTICE_KINDS, catalog::MET ])
    expect([ AddOmbudsman::ACTORS, AddOmbudsman::ACCESS_SCOPES, AddOmbudsman::UPLOADERS, AddOmbudsman::REOPEN_STATES,
             AddOmbudsman::REPORT_STATES, AddOmbudsman::DAILY_RUN_KINDS, AddOmbudsman::SUBJECT_TREE ])
      .to eq([ OmbudsmanEvent::ACTORS, OmbudsmanIdentityAccess::SCOPES, OmbudsmanAttachment::UPLOADERS, OmbudsmanReopenRequest::STATES,
               OmbudsmanAnnualReport::STATES, OmbudsmanDailyRun::KINDS, OmbudsmanSubject::DEFAULT_TREE ])
    expect(AddOmbudsman::TABLES.size).to eq(13)
  end

  it "protocolo AAAA-NNNNNN sequencial e único; o ano é o local" do
    travel_to Time.zone.local(2026, 12, 31, 23, 59) do
      a = OmbudsmanManifestation.next_protocol(Time.current)
      b = OmbudsmanManifestation.next_protocol(Time.current + 2.minutes)
      expect(a).to match(/\A2026-\d{6}\z/)
      expect(b).to start_with("2027-")
      expect(b.split("-").last.to_i).to eq(a.split("-").last.to_i + 1)
    end
    m = raw_manifestation!
    expect { raw_manifestation!(protocol: m.protocol) }.to raise_error(ActiveRecord::RecordNotUnique)
    refused(/ck_ombudsman_manifestations_protocol/) { raw_manifestation!(protocol: "26-1") }
  end

  it "colunas do registro nunca mudam; citizen_id só vai a nulo, com os manifestant_* juntos" do
    m = raw_manifestation!(citizen: web_citizen!)
    refused(/ombudsman_manifestations/) { m.update_columns(body: "outro texto da manifestação") }
    refused(/ombudsman_manifestations/) { m.update_columns(channel: "phone") }
    refused(/ombudsman_manifestations/) { m.update_columns(received_at: 1.day.ago) }
    refused(/manifestant/) { m.update_columns(manifestant_name: "Fulano") }
    accepted { m.update_columns(citizen_id: nil, manifestant_name: "Maria Souza") }
    expect(m.reload.manifestant_name).to eq("Maria Souza")
    refused(/citizen_id/) { m.update_columns(citizen_id: web_citizen!(cpf: "11144477735").id) }
    refused(/DELETE refused/) { m.destroy }
    accepted { m.reload.update!(state: "in_analysis", urgent: true) }
  end

  it "U1: nasce com cidadão e o nome declarado; na saída do cidadão o nome fica, o que falta pode entrar" do
    m = raw_manifestation!(citizen: web_citizen!, manifestant_name: "Ana")
    accepted { m.update_columns(citizen_id: nil, manifestant_cpf: "52998224725", manifestant_contact: "41998765432") }
    expect(m.reload.manifestant_name).to eq("Ana")
    expect(m.manifestant_cpf).to eq("52998224725")
    refused(/manifestant/) { m.update_columns(citizen_id: nil, manifestant_name: "Outra") }

    other = raw_manifestation!(citizen: web_citizen!, manifestant_name: "Ana")
    refused(/manifestant/) { other.update_columns(citizen_id: nil, manifestant_name: "Outra") }
    refused(/manifestant/) { other.reload.update_columns(citizen_id: nil, manifestant_name: nil) }
  end

  it "Q57: manifestant_phone segue os outros manifestant_* — só de NULL a valor quando citizen_id vai a nulo, e então nunca muda" do
    m = raw_manifestation!(citizen: web_citizen!)
    refused(/manifestant/) { m.update_columns(manifestant_phone: "+5541998765432") }
    accepted { m.reload.update_columns(citizen_id: nil, manifestant_phone: "+5541998765432") }
    expect(m.reload.manifestant_phone).to eq("+5541998765432")
    refused(/manifestant/) { m.update_columns(manifestant_phone: "+5541911112222") }
    refused(/manifestant/) { m.reload.update_columns(manifestant_phone: nil) }
    refused(/manifestant/) { m.reload.update_columns(manifestant_phone: m.manifestant_phone) } # a cifra nova do mesmo texto

    kept = raw_manifestation!(citizen: web_citizen!, manifestant_phone: "+5541998765432")
    refused(/manifestant/) { kept.update_columns(citizen_id: nil, manifestant_phone: "+5541911112222") }
    refused(/manifestant/) { kept.reload.update_columns(citizen_id: nil, manifestant_phone: nil) }

    expect { raw_manifestation!(kind: "report", identification_mode: "anonymous", manifestant_phone: "+5541998765432") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_manifestations_anonymous/)
  end

  it "anônima só denúncia e sem dado de pessoa; eventos, acessos e satisfação são só acréscimo" do
    expect { raw_manifestation!(kind: "complaint", identification_mode: "anonymous") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_manifestations_anonymous/)
    expect { raw_manifestation!(kind: "report", identification_mode: "anonymous", manifestant_name: "Fulano") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_manifestations_anonymous/)
    expect(raw_manifestation!(kind: "report", identification_mode: "anonymous")).to be_anonymous

    m = raw_manifestation!
    event = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "received", actor: "system", data: {}, visible_to_citizen: true)
    refused(/append-only/) { event.update_columns(visible_to_citizen: false) }
    refused(/append-only/) { event.destroy }
    expect { OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "received", actor: "staff", data: {}) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_events_actor_user/)

    access = OmbudsmanIdentityAccess.create!(ombudsman_manifestation: m, user: ombudsman!, scope: "identity",
                                             justification: "Resposta exige contato direto com a pessoa.")
    refused(/append-only/) { access.update_columns(scope: "attachment") }
    refused(/append-only/) { access.destroy }
    expect { OmbudsmanIdentityAccess.create!(ombudsman_manifestation: m, user: ombudsman!, scope: "attachment", justification: "Abrir o anexo.") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_identity_accesses_file/)

    survey = OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: m, met: "partly", clear: true, score: 4)
    refused(/append-only/) { survey.update_columns(score: 5) }
    refused(/append-only/) { survey.destroy }
    expect { OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: m, met: "yes", clear: true, score: 5) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect { OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: raw_manifestation!, met: "yes", clear: true, score: 6) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_satisfaction_responses_score/)
  end

  it "estado, arquivamento, duplicata, canal OuvidorSUS e criador seguem os CHECKs" do
    m = raw_manifestation!
    refused(/ck_ombudsman_manifestations_archived/) { m.update_columns(state: "archived") }
    refused(/ck_ombudsman_manifestations_duplicate/) { m.update_columns(duplicate_of_id: raw_manifestation!.id) }
    refused(/ck_ombudsman_manifestations_duplicate/) { m.update_columns(state: "archived", archive_reason: "duplicate") }
    refused(/ck_ombudsman_manifestations_elsewhere/) { m.update_columns(external_body_name: "Ouvidoria do Estado") }
    accepted { m.update_columns(state: "archived", archive_reason: "forwarded_elsewhere", external_body_name: "Ouvidoria do Estado") }
    refused(/ck_ombudsman_manifestations_state/) { raw_manifestation!.update_columns(state: "closed") }
    expect { raw_manifestation!(channel: "ouvidorsus", ouvidorsus_number: nil) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_manifestations_ouvidorsus/)
    expect(raw_manifestation!(channel: "ouvidorsus").ouvidorsus_number).to be_present
    expect { raw_manifestation!(channel: "phone", created_by_user: nil) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_manifestations_web_creator/)
    expect { raw_manifestation!(channel: "web", created_by_user: ombudsman_staff!) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_manifestations_web_creator/)
    refused(/ck_ombudsman_manifestations_cycle/) { m.update_columns(cycle: 0) }
  end

  it "encaminhamento: extrato imutável, resposta uma vez; aviso só read_at; relatório publicado congela" do
    m = raw_manifestation!(citizen: web_citizen!)
    f = forwarding!(m)
    refused(/ombudsman_forwardings/) { f.update_columns(extract: "Outro extrato do caso para o setor.") }
    refused(/ombudsman_forwardings/) { f.update_columns(department_id: department!.id) }
    refused(/ombudsman_forwardings/) { f.update_columns(due_on: f.due_on + 5) }
    refused(/ck_ombudsman_forwardings_reply/) { f.update_columns(state: "replied") }
    refused(/DELETE refused/) { f.destroy }

    accepted { f.reload.update!(extended: true, due_on: f.due_on + 20, extension_reason: "Aguardando o relatório da unidade.") }
    refused(/extended once/) { f.update_columns(extended: false) }
    accepted { f.reload.update!(state: "replied", reply: "Equipe orientada e escala revista.", replied_by_user: ombudsman!, replied_at: Time.current) }
    refused(/ombudsman_forwardings/) { f.update_columns(reply: "Outra resposta do setor.") }
    refused(/ombudsman_forwardings/) { f.update_columns(state: "cancelled") }
    expect { forwarding!(m, destination: department!).tap { |g| g.update!(health_unit: create_unit("UBS Encaminhada")) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ombudsman_forwardings/)
    expect { OmbudsmanForwarding.create!(ombudsman_manifestation: m, department: department!, health_unit: create_unit("UBS Dupla"),
                                         extract: "Extrato com dois destinos ao mesmo tempo.", due_on: Date.current, state: "pending",
                                         created_by_user: ombudsman_staff!) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_forwardings_destination/)

    notice = OmbudsmanNotice.create!(citizen: m.citizen, ombudsman_manifestation: m, kind: "final_response")
    refused(/only read_at/) { notice.update_columns(kind: "archived") }
    accepted { notice.update_columns(read_at: Time.current) }
    refused(/read once/) { notice.update_columns(read_at: Time.current + 1.minute) }
    accepted { notice.destroy }
    expect { OmbudsmanNotice.create!(citizen: m.citizen, ombudsman_manifestation: m, kind: "reminder") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_notices_kind/)

    report = OmbudsmanAnnualReport.create!(year: 2025, state: "draft", notes: "Rascunho")
    accepted { report.update!(notes: "Rascunho revisto") }
    refused(/ck_ombudsman_annual_reports_published/) { report.update_columns(state: "published") }
    accepted { report.reload.update!(state: "published", snapshot: { "total" => 10 }, published_at: Time.current, published_by_user: ombudsman!) }
    refused(/published report never changes/) { report.update_columns(notes: "Alterado depois") }
    refused(/DELETE refused/) { report.destroy }
    expect { OmbudsmanAnnualReport.create!(year: 2025, state: "draft") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "pedido de reabertura: um pendente, um por ciclo, decidido uma vez e com quem decidiu" do
    m = raw_manifestation!(state: "answered", concluded_at: Time.current, resolution: "resolved")
    request = OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 1, reason: "A resposta não resolveu o problema.", state: "pending")
    expect { OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 2, reason: "Outro pedido de reabertura.", state: "pending") }
      .to raise_error(ActiveRecord::RecordNotUnique)
    refused(/ombudsman_reopen_requests/) { request.update_columns(reason: "Mudei o motivo do pedido.") }
    refused(/ck_ombudsman_reopen_requests_decided/) { request.update_columns(state: "rejected") }
    accepted { request.reload.update!(state: "rejected", decision_text: "A resposta segue válida.", decided_by_user: ombudsman!, decided_at: Time.current) }
    refused(/ombudsman_reopen_requests/) { request.update_columns(state: "accepted") }
    refused(/DELETE refused/) { request.destroy }
    expect { OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 1, reason: "De novo no mesmo ciclo.", state: "pending") }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "o anexo órfão some com o arquivo órfão; o ligado nunca" do
    orphan = raw_attachment!
    linked = raw_attachment!(manifestation: raw_manifestation!)
    ExamFile.where(id: orphan.exam_file_id).delete_all
    expect(OmbudsmanAttachment.exists?(orphan.id)).to be(false)
    refused(/ombudsman_attachments/) { linked.destroy }
    refused(/ombudsman_attachments/) { linked.update_columns(ombudsman_manifestation_id: raw_manifestation!.id) }

    pending_link = raw_attachment!(uploaded_by: "staff")
    refused(/ombudsman_attachments/) { pending_link.update_columns(filename: "outro-nome.png") }
    m = raw_manifestation!
    event = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "complement_received", actor: "citizen", data: {})
    # A ligação exige o arquivo consumido: senão o delete_all do Exams::DailyJob
    # (o órfão de 24 h) abortaria a cidade inteira.
    refused(/ombudsman_attachments: .*consumed/) { pending_link.update_columns(ombudsman_manifestation_id: m.id, event_id: event.id) }
    pending_link.exam_file.update!(consumed_at: Time.current)
    accepted { pending_link.reload.update_columns(ombudsman_manifestation_id: m.id, event_id: event.id) }
    refused(/ombudsman_attachments/) { pending_link.update_columns(event_id: nil) }
    expect { OmbudsmanAttachment.create!(exam_file: pdf_file!, filename: "x.pdf", uploaded_by: "citizen") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_attachments_owner/)
  end

  it "re-cifra passa nas tabelas imutáveis; fora da marca, a mesma escrita é recusada" do
    expect(CityEncryption::CITY_KEYED_TARGETS).to include(
      *%i[manifestant_name manifestant_contact manifestant_cpf manifestant_phone body extension_reason]
        .map { |c| [ OmbudsmanManifestation, c ] },
      [ OmbudsmanEvent, :text ], *%i[extract extension_reason reply].map { |c| [ OmbudsmanForwarding, c ] },
      [ OmbudsmanIdentityAccess, :justification ], [ OmbudsmanAttachment, :filename ],
      [ OmbudsmanReopenRequest, :reason ], [ OmbudsmanReopenRequest, :decision_text ]
    )
    m = raw_manifestation!(citizen: web_citizen!, manifestant_name: "Ana")
    event = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "interim_response", actor: "staff", actor_user: ombudsman_staff!,
                                   text: "Estamos apurando com a unidade.", data: {}, visible_to_citizen: true)
    f = forwarding!(m)
    access = OmbudsmanIdentityAccess.create!(ombudsman_manifestation: m, user: ombudsman!, scope: "identity",
                                             justification: "Contato necessário para a resposta.")
    attachment = raw_attachment!(manifestation: m)
    request = OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 1, reason: "A resposta não resolveu o problema.", state: "pending")
    erased = raw_manifestation!(manifestant_name: "Ana", manifestant_cpf: "52998224725", manifestant_phone: "+5541998765432")

    [ [ m, :body ], [ erased, :manifestant_phone ], [ event, :text ], [ f, :extract ], [ access, :justification ],
      [ attachment, :filename ], [ request, :reason ] ].each do |record, column|
      before = record.ciphertext_for(column)
      expect { CityEncryption.allowing_reencryption { record.encrypt } }.not_to raise_error
      record.reload
      expect(record.ciphertext_for(column)).not_to eq(before)
      clear = record.public_send(column)
      refused(/#{record.class.table_name}/) { record.update_columns(column => clear) }
    end
    refused(/ombudsman_manifestations/) { CityEncryption.allowing_reencryption { m.reload.update_columns(body: m.body, urgent: true) } }
    expect(m.reload.body).to eq(OmbudsmanHelpers::BODY)
  end

  it "assuntos: dois níveis, nome único por pai sem caixa, nunca apagados; a semente só entra com a tabela vazia" do
    parent = OmbudsmanSubject.find_by!(name: "Atendimento", parent_id: nil)
    child = OmbudsmanSubject.find_by!(name: "Demora", parent: parent)
    expect(OmbudsmanSubject.where(parent_id: nil).count).to eq(8)
    expect(OmbudsmanSubject.count).to eq(8 + 12)
    expect(subject_leaf!.parent_id).to be_present

    expect { OmbudsmanSubject.create!(name: "Neto", parent: child) }.to raise_error(ActiveRecord::StatementInvalid, /two levels/)
    refused(/two levels/) { OmbudsmanSubject.find_by!(name: "Acesso").update_columns(parent_id: parent.id) }
    expect { OmbudsmanSubject.create!(name: "dEMORA", parent: parent) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { OmbudsmanSubject.create!(name: "Demora", parent: OmbudsmanSubject.find_by!(name: "Acesso")) }.not_to raise_error
    refused(/DELETE refused/) { child.destroy }

    parent.update!(name: "Atendimento ao público")
    child.reload.update!(active: false)
    Ombudsman::Settings.ensure_defaults!
    expect(OmbudsmanSubject.where(name: "Atendimento")).to be_empty
    expect(child.reload.active).to be(false)
    expect(OmbudsmanSetting.current.response_days).to eq(30)
  end

  it "a configuração tem uma linha com faixas; respondente com um destino só, sem repetir; nada disso some" do
    setting = OmbudsmanSetting.current
    expect(setting.attributes.slice(*%w[response_days extension_days urgent_days complement_days forwarding_days
                                        forwarding_extension_days warning_days anonymous_daily_cap]).values)
      .to eq([ 30, 30, 15, 20, 20, 20, 5, 50 ])
    refused(/ck_ombudsman_settings_ranges/) { setting.update_columns(response_days: 121) }
    refused(/ck_ombudsman_settings_ranges/) { setting.update_columns(anonymous_daily_cap: 1001) }
    refused(/ck_ombudsman_settings_singleton/) { OmbudsmanSetting.insert_all([ { id: 2, updated_at: Time.current } ]) }
    refused(/DELETE refused/) { setting.destroy }

    unit = create_unit("UBS Ouvidoria")
    user = responder!(unit)
    row = OmbudsmanResponder.find_by!(user: user)
    expect { OmbudsmanResponder.create!(user: user, health_unit: unit, created_by_user: ombudsman!) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { OmbudsmanResponder.create!(user: user, department: department!, created_by_user: ombudsman!) }.not_to raise_error
    expect { OmbudsmanResponder.create!(user: user, created_by_user: ombudsman!) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ombudsman_responders_destination/)
    accepted { row.update!(active: false) }
    refused(/DELETE refused/) { row.destroy }

    OmbudsmanDailyRun.insert_all([ { run_on: Date.current, kind: "deadlines" } ])
    expect(OmbudsmanDailyRun.insert_all([ { run_on: Date.current, kind: "deadlines" } ]).rows).to be_empty
    refused(/ck_ombudsman_daily_runs_kind/) { OmbudsmanDailyRun.insert_all([ { run_on: Date.current, kind: "other" } ]) }
    refused(/DELETE refused/) { OmbudsmanDailyRun.delete_all }
    refused(/TRUNCATE/) { ApplicationRecord.connection.execute("TRUNCATE ombudsman_manifestations CASCADE") }
  end

  it "nada de texto nem de identidade em inspect, to_s, pretty_print e as_json" do
    m = raw_manifestation!(citizen: web_citizen!, manifestant_name: "Ana Secreta")
    event = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "interim_response", actor: "staff", actor_user: ombudsman_staff!,
                                   text: "Texto sigiloso da resposta", data: {})
    f = forwarding!(m)
    f.update!(state: "replied", reply: "Resposta sigilosa do setor", replied_by_user: ombudsman!, replied_at: Time.current)
    records = [ m, event, f, raw_attachment!(filename: "nome-sigiloso.png"),
                OmbudsmanIdentityAccess.create!(ombudsman_manifestation: m, user: ombudsman!, scope: "identity", justification: "Justificativa sigilosa"),
                OmbudsmanReopenRequest.create!(ombudsman_manifestation: m, cycle: 1, reason: "Motivo sigiloso do pedido", state: "pending"),
                OmbudsmanNotice.create!(citizen: m.citizen, ombudsman_manifestation: m, kind: "final_response"),
                OmbudsmanSatisfactionResponse.create!(ombudsman_manifestation: m, met: "no", clear: false, score: 1) ]
    records.each do |record|
      shown = [ record.inspect, record.to_s, record.pretty_inspect, record.as_json.to_s ].join
      expect(shown).to include(record.id)
      expect(shown).not_to match(/sigilos|Secreta|Fiquei|Extrato|#{m.citizen_id}/)
      expect(record.as_json.keys - %w[id state]).to eq([])
    end
    expect(m.as_json).to eq("id" => m.id, "state" => "received")
    expect(m).to be_open
    expect(m).not_to be_final
    expect(m).not_to be_identity_protected
    expect(raw_manifestation!(identification_mode: "preserved")).to be_identity_protected
  end
end

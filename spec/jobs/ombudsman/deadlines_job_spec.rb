require "rails_helper"

# Módulo 33, Task 17 (ADR 0051; contrato §12; §16 Q11, Q36): o job diário das
# 10h (Q59). Arquiva com `no_complement` o complemento vencido (vence em
# complement_requested_at::date + complement_days; arquiva no dia seguinte),
# e-mail só com números aos ouvidores/técnicos e a cada respondente.
RSpec.describe Ombudsman::DeadlinesJob do
  include ActiveSupport::Testing::TimeHelpers
  include ActiveJob::TestHelper

  before do
    ombudsman_city!
    travel_to Time.zone.local(2026, 11, 11, 10, 0)
    staff_with("ouvidora@cidade.gov.br", "ombudsman")
    staff_with("tecnico@cidade.gov.br", "ombudsman_staff")
    ActionMailer::Base.deliveries.clear
  end
  after do
    travel_back
    Current.reset
  end

  def run! = perform_enqueued_jobs { described_class.perform_now }
  def deliveries = ActionMailer::Base.deliveries
  def full_text(mail) = [ mail.subject, mail.text_part.body.decoded, mail.html_part.body.decoded ].join("\n")

  def awaiting!(requested_days_ago, citizen: web_citizen!)
    at = requested_days_ago.days.ago
    raw_manifestation!(citizen: citizen, state: "awaiting_complement", complement_requested_at: at,
                       received_at: at - 3.days, cycle_started_on: (at - 3.days).to_date)
  end

  def open_on(days_ago, **attrs) = raw_manifestation!(state: "in_analysis", received_at: days_ago.days.ago, cycle_started_on: days_ago.days.ago.to_date, **attrs)

  describe "complemento vencido" do
    it "arquiva com no_complement, evento system, aviso ao cidadão e ombudsman.concluded" do
      expired = awaiting!(21)

      expect { run! }.to change { DomainEvent.where(name: "ombudsman.concluded").count }.by(1)

      expired.reload
      expect(expired.state).to eq("archived")
      expect(expired.archive_reason).to eq("no_complement")
      expect(expired.complement_requested_at).to be_nil
      event = OmbudsmanEvent.where(ombudsman_manifestation: expired, kind: "archived").sole
      expect(event.actor).to eq("system")
      expect(event.actor_user_id).to be_nil
      expect(OmbudsmanNotice.where(ombudsman_manifestation_id: expired.id, kind: "archived").count).to eq(1)
    end

    it "no último dia (há 20) e antes: intacta" do
      last_day = awaiting!(20)
      recent = awaiting!(3)

      run!

      expect(last_day.reload.state).to eq("awaiting_complement")
      expect(recent.reload.state).to eq("awaiting_complement")
    end

    it "o cidadão que respondeu no último dia não é arquivado na manhã seguinte" do
      manifestation = awaiting!(20)
      Ombudsman::RecordComplement.call(manifestation: manifestation, expected_state: "awaiting_complement", text: "Segue o complemento.",
                                       attachment_ids: [], actor: "staff", by: ombudsman_staff!, owner: nil)
      travel_to Time.zone.local(2026, 11, 12, 7, 0)
      ActionMailer::Base.deliveries.clear

      run!

      expect(manifestation.reload.state).to eq("in_analysis")
      expect(OmbudsmanEvent.where(ombudsman_manifestation: manifestation, kind: "archived")).to be_empty
    end

    it "só olha o estado awaiting_complement, mesmo com complement_requested_at preenchido" do
      stale = open_on(30, complement_requested_at: 25.days.ago)

      run!

      expect(stale.reload.state).to eq("in_analysis")
    end

    it "rodar duas vezes no dia arquiva uma vez e envia um e-mail" do
      expired = awaiting!(21)
      open_on(60)   # vermelha: gera o resumo

      expect { run!; run! }.to change { OmbudsmanEvent.where(ombudsman_manifestation: expired, kind: "archived").count }.by(1)

      expect(OmbudsmanDailyRun.where(kind: "deadlines", run_on: Date.new(2026, 11, 11)).count).to eq(1)
      expect(deliveries.map(&:to)).to contain_exactly([ "ouvidora@cidade.gov.br" ], [ "tecnico@cidade.gov.br" ])
    end

    it "a falha de uma não para as outras e o log leva só a classe" do
      first = awaiting!(22)
      second = awaiting!(21)
      allow(Ombudsman::Archive).to receive(:call).and_wrap_original do |original, **args|
        raise "texto sigiloso #{OmbudsmanHelpers::BODY}" if args[:manifestation_id] == first.id

        original.call(**args)
      end

      log = capture_log { expect { described_class.perform_now }.to raise_error(EachCityJob::AggregatedFailure) }

      expect(second.reload.state).to eq("archived")
      expect(first.reload.state).to eq("awaiting_complement")
      expect(log).not_to include(OmbudsmanHelpers::BODY)
    end

    it "um dia mudado (a resposta chegou entre a seleção e o arquivamento) não é arquivado" do
      manifestation = awaiting!(21)
      allow(Ombudsman::Archive).to receive(:call).and_wrap_original do |original, **args|
        manifestation.update_columns(state: "in_analysis", complement_requested_at: nil)
        original.call(**args)
      end

      run!

      expect(manifestation.reload.state).to eq("in_analysis")
      expect(OmbudsmanEvent.where(ombudsman_manifestation: manifestation, kind: "archived")).to be_empty
    end
  end

  describe "resumo por e-mail" do
    it "conta amarelas e vermelhas abertas, sem as pausadas, e só leva números" do
      # response_days 30, warning_days 5 (padrões): 60 dias = vermelha; 27 = amarela; 3 = verde.
      settings = OmbudsmanSetting.current
      reds = [ open_on(settings.response_days + 10), open_on(settings.response_days + 2) ]
      yellow = open_on(settings.response_days - 2)
      open_on(3)
      awaiting!(5)                                             # pausada
      unit = create_unit("UBS Sigilosa")
      open_on(settings.response_days + 5, referred_health_unit_id: unit.id)

      run!

      mail = deliveries.find { |m| m.to == [ "ouvidora@cidade.gov.br" ] }
      expect(mail.subject).to eq("[rota-saúde] Resumo diário de prazos da ouvidoria")
      text = full_text(mail)
      expect(text).to include("Manifestações vermelhas (prazo vencido): 3", "Manifestações amarelas (a vencer): 1", "painel da cidade")
      forbidden = (reds + [ yellow ]).flat_map { |m| [ m.protocol, m.id ] } + [ OmbudsmanHelpers::BODY, "UBS Sigilosa", unit.id, "http" ]
      forbidden.each { |value| expect(text).not_to include(value) }
    end

    it "não envia nada quando tudo é zero" do
      open_on(3)

      run!

      expect(deliveries).to be_empty
    end

    it "cada respondente recebe só a contagem dos encaminhamentos dele" do
      settings = OmbudsmanSetting.current
      department = department!
      other = department!
      mine = responder!(department)
      theirs = responder!(other)
      manifestation = open_on(5)
      forward = ->(dest, due_on, state = "pending") do
        OmbudsmanForwarding.create!(ombudsman_manifestation: manifestation, department: dest, extract: "Trecho sigiloso do caso",
                                    state: state, due_on: due_on, created_by_user: ombudsman!)
      end
      today = Date.new(2026, 11, 11)
      forward.call(department, today - 2)                            # vermelho
      forward.call(department, today + settings.warning_days)        # amarelo
      forward.call(department, today + settings.warning_days + 10)   # verde
      forward.call(other, today - 1)
      forward.call(other, today - 1)
      OmbudsmanForwarding.where(department_id: department.id, due_on: today - 2).update_all(updated_at: Time.current)

      run!

      mine_mail = deliveries.find { |m| m.to == [ mine.email_address ] }
      theirs_mail = deliveries.find { |m| m.to == [ theirs.email_address ] }
      expect(mine_mail.subject).to eq("[rota-saúde] Seus encaminhamentos da ouvidoria")
      expect(full_text(mine_mail)).to include("Encaminhamentos pendentes: 3", "vencidos: 1", "a vencer: 1")
      expect(full_text(theirs_mail)).to include("Encaminhamentos pendentes: 2", "vencidos: 2", "a vencer: 0")
      [ mine_mail, theirs_mail ].each do |m|
        expect(full_text(m)).not_to include("Trecho sigiloso", manifestation.protocol, "http")
      end
    end

    it "respondente sem encaminhamento pendente não recebe e-mail" do
      responder!(department!)
      open_on(3)

      run!

      expect(deliveries).to be_empty
    end
  end

  it "interruptor desligado: nada acontece, nem a marca do dia" do
    expired = awaiting!(21)
    Platform::Features.set!(city: Current.city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)

    run!

    expect(expired.reload.state).to eq("awaiting_complement")
    expect(OmbudsmanDailyRun.where(kind: "deadlines")).to be_empty
    expect(deliveries).to be_empty
  end

  it "não atribui Current.city fora do bloco da cidade" do
    city = Current.city
    Current.reset
    described_class.perform_now
    expect(Current.city).to be_nil
    expect(city).to be_present
  end

  # Q59: 10h de Brasília é 8h no Acre (UTC−5): o SMS do no_complement cai na
  # janela das 8h às 20h em todo fuso do país.
  it "está agendado todo dia às 10h no fuso de São Paulo, na fila housekeeping" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("default").fetch("ombudsman_deadlines")
    expect(task).to include("class" => "Ombudsman::DeadlinesJob", "queue" => "housekeeping",
                            "schedule" => "every day at 10am America/Sao_Paulo")
  end
end

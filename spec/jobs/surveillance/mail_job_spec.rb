require "rails_helper"

# Módulo 25, Task 13 (ADR 0043): o e-mail da imediata leva doença e unidade e
# nunca o paciente, o bairro, a data de sintomas nem o id da notificação.
RSpec.describe Surveillance::MailJob do
  include ActiveJob::TestHelper

  before { surveillance_city! }
  after { Current.reset }

  let(:unit) { create_unit("UBS Vigia Norte") }
  let!(:officers) do
    [ surveillance_officer!("vig-um@cidade.gov.br"), surveillance_officer!("vig-dois@cidade.gov.br") ]
  end

  def deliver!(kind, ref) = described_class.perform_now(city_slug: Current.city.slug, kind: kind, ref: ref)
  def deliveries = ActionMailer::Base.deliveries
  def full_text(mail) = [ mail.subject, mail.text_part.body.decoded, mail.html_part.body.decoded ].join("\n")

  def sarampo!(n: 1, **over)
    patient, citizen = exam_patient!(n, full_name: "Maria Aparecida da Silva")
    patient.update!(cns: Professionals::Cns.generate("paciente-#{n}"))
    centro = Neighborhood.create!(name: "Bairro Sigiloso #{SecureRandom.hex(2)}", source: "manual")
    Citizen.where(patient_id: patient.id).update_all(neighborhood_id: centro.id)
    notification = notification!(patient: patient, disease_code: "sarampo", unit: unit, by: officers.first, symptoms_on: Time.zone.today - 3, **over)
    [ notification, patient, citizen, centro ]
  end

  describe "immediate" do
    it "entrega a cada membro ativo (não ao desativado nem ao de papel revogado) sem dado do paciente" do
      gone = surveillance_officer!("gone@cidade.gov.br")
      gone.update!(deactivated_at: Time.current)
      revoked = surveillance_officer!("revoked@cidade.gov.br")
      Membership.where(user: revoked).update_all(revoked_at: Time.current)
      staff_with("outro@cidade.gov.br", "viewer")
      notification, patient, citizen, centro = sarampo!
      deliveries.clear

      deliver!("immediate", notification.id)

      expect(deliveries.map(&:to)).to contain_exactly([ "vig-um@cidade.gov.br" ], [ "vig-dois@cidade.gov.br" ])
      mail = deliveries.last
      expect(mail.subject).to eq("[rota-saúde] Nova notificação imediata: Sarampo, UBS Vigia Norte")
      text = full_text(mail)
      expect(text).to include("Sarampo", "UBS Vigia Norte", "painel da cidade")
      # Os valores proibidos existem de fato na fixture (nada de teste vazio).
      expect(citizen.cpf).to be_present
      expect(patient.reload.cns).to match(/\A\d{15}\z/)
      expect(notification.neighborhood_id).to eq(centro.id)
      expect(notification.symptoms_on).to be_present
      forbidden = [ "Maria", "Aparecida", citizen.cpf, citizen.cpf.gsub(/\D/, ""), patient.cns, centro.name,
                    notification.id, notification.symptoms_on.to_s, notification.symptoms_on.strftime("%d/%m/%Y"),
                    notification.suspected_on.to_s, "http" ]
      forbidden.each { |value| expect(text).not_to include(value) }
      expect(text).not_to include("possível notificação não feita")
    end

    it "origem rede de segurança (situação possible na linha): avisa que falta confirmar na fila" do
      patient = surveillance_patient!(2)
      notification = notification!(patient: patient, disease_code: "sarampo", unit: unit, origin: "safety_net")
      deliveries.clear

      deliver!("immediate", notification.id)

      expect(deliveries.size).to eq(2)
      expect(full_text(deliveries.last)).to include("possível notificação não feita — confirmar na fila")
    end

    it "lê a situação da linha: a que já virou notified não é mais possível" do
      notification = notification!(patient: surveillance_patient!(3), disease_code: "sarampo", unit: unit, origin: "safety_net")
      notification.update_columns(status: "notified")
      deliveries.clear

      deliver!("immediate", notification.id)

      expect(full_text(deliveries.last)).not_to include("possível notificação não feita")
    end

    it "entrega uma rodada" do
      notification, = sarampo!(n: 4)
      deliveries.clear

      deliver!("immediate", notification.id)
      deliver!("immediate", notification.id)

      expect(deliveries.size).to eq(2) # rodar duas vezes: um e-mail por membro, uma rodada só
      expect(ProcessedEvent.where(consumer: "surveillance_mail", event_id: "immediate:#{notification.id}").count).to eq(1)
    end

    it "sem destinatário: sem erro, sem e-mail, log só com a contagem" do
      Membership.update_all(revoked_at: Time.current)
      notification, = sarampo!(n: 5)
      deliveries.clear
      allow(Rails.logger).to receive(:info).and_call_original

      expect { deliver!("immediate", notification.id) }.not_to raise_error

      expect(deliveries).to be_empty
      expect(Rails.logger).to have_received(:info).with("[Surveillance::MailJob] kind=immediate recipients=0 delivered=0 failed=0")
    end

    it "notificação inexistente: nada a enviar, sem erro" do
      deliveries.clear
      expect { deliver!("immediate", SecureRandom.uuid) }.not_to raise_error
      expect(deliveries).to be_empty
    end

    it "recusa permanente de um endereço não cala os demais: pula, conta e segue" do
      notification, = sarampo!(n: 9)
      deliveries.clear
      allow(Rails.logger).to receive(:info).and_call_original
      calls = 0
      allow_any_instance_of(Mail::Message).to receive(:deliver).and_wrap_original do |original, *args|
        calls += 1
        raise Net::SMTPFatalError, "550 mailbox unavailable" if calls == 1

        original.call(*args)
      end

      expect { deliver!("immediate", notification.id) }.not_to raise_error

      expect(deliveries.size).to eq(1)
      expect(Rails.logger).to have_received(:info).with("[Surveillance::MailJob] kind=immediate recipients=2 delivered=1 failed=1")
    end

    it "erro transitório de SMTP é retentado e o dedup é desfeito" do
      notification, = sarampo!(n: 6)
      deliveries.clear
      allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::ReadTimeout)

      expect { deliver!("immediate", notification.id) }.not_to raise_error

      expect(ProcessedEvent.where(consumer: "surveillance_mail", event_id: "immediate:#{notification.id}")).to be_empty
      assert_enqueued_with(job: described_class)
    end
  end

  describe "overdue" do
    it "leva só contagens: vencidas e imediatas entre elas" do
      notification, = sarampo!(n: 7)
      weekly = notification!(patient: surveillance_patient!(8), disease_code: "dengue", unit: unit, by: officers.first)
      notification.update_columns(due_at: 2.hours.ago)
      weekly.update_columns(due_at: 1.hour.ago)
      deliveries.clear

      deliver!("overdue", Time.zone.today.iso8601)

      mail = deliveries.last
      expect(deliveries.size).to eq(2)
      expect(mail.subject).to eq("[rota-saúde] Notificações vencidas: 2")
      text = full_text(mail)
      expect(text).to include("Vencidas: 2", "Imediatas entre elas: 1")
      expect(text).not_to include("Sarampo", "Dengue", "UBS Vigia Norte", notification.id, "http")
    end

    it "contagem zerada na hora do envio: nada" do
      deliveries.clear
      deliver!("overdue", Time.zone.today.iso8601)
      expect(deliveries).to be_empty
    end
  end

  describe "portão" do
    it "overdue e negatives conferem o interruptor ao enviar; immediate não" do
      notification, = sarampo!(n: 10)
      notification.update_columns(due_at: 1.hour.ago)
      create_unit("UBS Sem Negativa")
      week = Surveillance::EpiWeek.current(Time.zone.today).pred
      Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
      deliveries.clear

      deliver!("overdue", Time.zone.today.iso8601)
      deliver!("negatives", week.to_s)
      expect(deliveries).to be_empty

      deliver!("immediate", notification.id)
      expect(deliveries.size).to eq(2)
    end
  end

  describe "negatives" do
    it "lista os nomes das unidades pendentes da semana" do
      create_unit("UBS Sem Negativa")
      reported = create_unit("UBS Com Negativa")
      week = Surveillance::EpiWeek.current(Time.zone.today).pred
      WeeklyNegativeReport.create!(health_unit: reported, week: week.to_s, recorded_by_user: officers.first)
      deliveries.clear

      deliver!("negatives", week.to_s)

      mail = deliveries.last
      expect(deliveries.size).to eq(2)
      text = full_text(mail)
      expect(text).to include(week.to_s, "UBS Sem Negativa")
      expect(text).not_to include("UBS Com Negativa")
    end
  end

  it "rejeita kind desconhecido" do
    expect { deliver!("outro", "x") }.to raise_error(ArgumentError)
  end
end

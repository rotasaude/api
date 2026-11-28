require "rails_helper"

# Módulo 26c, Task 7 (Valores 5 e 6; Q7; Review Focus 2): a correspondência
# entre a situação do pedido da 26a e a situação do MIRA, e os passos
# intermediários da falta. Regras puras sobre fatos já lidos; os pedidos nascem
# pelos comandos reais da 26a.
RSpec.describe Regulation::RndsStatus, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }
  let(:settings) { RegulationRndsSetting.current }
  let(:regulator) { regulation_regulator! }
  let(:offer) { offer!(provider: external_provider!) }

  before do
    travel_to now
    regulation_city!
    tick_regulation_events!
  end

  def slot_columns = { scheduled_at: Time.current - 1.day, ends_at: Time.current - 1.day + 15.minutes, care_provider_id: offer.care_provider_id }
  def target(request, config = settings) = described_class.for(request.reload, settings: config)
  def last_event_at(request, status) = request.events.select { |e| e.status == status }.last.created_at

  def schedule!(request, at: Time.current + 3.days)
    result = CareRegulation::ScheduleExternal.call(request: request.reload, at: at.iso8601, place: "Hospital Regional", notes: nil,
                                                   version: request.version, by: regulator, care_provider_id: offer.care_provider_id)
    raise "agendamento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  def miss!(request)
    ApplicationRecord.transaction do
      request.lock!(CareRegulation::Decide::LOCK)
      CareRegulation::Misses.apply!(request: request, by: regulator)
    end
    request.reload
  end

  def decide!(request, decision)
    result = CareRegulation::Decide.call(request: request.reload, decision: decision, reason: "Motivo da decisão de teste",
                                         version: request.version, by: regulator)
    raise "decisão recusada: #{result.reason}" if result.failure?

    request.reload
  end

  describe ".for" do
    it "draft -> :none" do
      expect(target(regulation_request!(status: "draft"))).to eq(:none)
    end

    it "pending -> pending, com at = requested_at (sem linha própria)" do
      request = regulation_request!
      expect(target(request)).to eq(described_class::Target.new(status: "pending", at: last_event_at(request, "pending")))
    end

    it "authorized -> pending, com at da linha authorized" do
      request = reauthorize!(regulation_request!, offer: offer)
      expect(request.status).to eq("authorized")
      expect(target(request)).to eq(described_class::Target.new(status: "pending", at: last_event_at(request, "authorized")))
    end

    it "returned -> returned-to-requester" do
      request = decide!(regulation_request!, "return")
      expect(target(request)).to eq(described_class::Target.new(status: "returned-to-requester", at: last_event_at(request, "returned")))
    end

    it "scheduled -> booked, com at do andamento scheduled" do
      request = schedule!(reauthorize!(regulation_request!, offer: offer))
      expect(request.status).to eq("scheduled")
      expect(target(request)).to eq(described_class::Target.new(status: "booked", at: last_event_at(request, "scheduled")))
    end

    it "completed -> attended" do
      request = schedule!(reauthorize!(regulation_request!, offer: offer), at: Time.current)
      result = CareRegulation::RecordOutcome.call(request: request, result: "completed", version: request.version, by: regulator)
      raise "desfecho recusado: #{result.reason}" if result.failure?

      expect(target(request)).to eq(described_class::Target.new(status: "attended", at: last_event_at(request, "completed")))
    end

    it "denied e cancelled -> cancelled" do
      denied = decide!(regulation_request!, "deny")
      cancelled = decide!(regulation_request!, "cancel")
      expect(target(denied)).to eq(described_class::Target.new(status: "cancelled", at: last_event_at(denied, "denied")))
      expect(target(cancelled)).to eq(described_class::Target.new(status: "cancelled", at: last_event_at(cancelled, "cancelled")))
    end

    it "closed pela segunda falta -> absence, com at da linha closed" do
      request = reauthorize!(miss!(reauthorize!(regulation_request!, offer: offer)), offer: offer)
      request = miss!(request)
      expect(request).to have_attributes(status: "closed", misses: 2)
      expect(target(request)).to eq(described_class::Target.new(status: "absence", at: last_event_at(request, "closed")))
    end

    it "closed sem as faltas -> cancelled" do
      request = regulation_request!
      request.update_columns(status: "closed", misses: 0)
      RegulationRequestEvent.create!(regulation_request: request, status: "closed", by_user: regulator)
      expect(target(request).status).to eq("cancelled")
    end

    describe "pedido regulado pelo estado (Q7)" do
      it "external com send_external desligado -> :excluded; ligado -> pending" do
        request = regulation_request!(status: "external")
        expect(target(request, instance_double(RegulationRndsSetting, send_external: false))).to eq(:excluded)
        expect(target(request, instance_double(RegulationRndsSetting, send_external: true)).status).to eq("pending")
      end

      it "scheduled e completed, ligado -> booked e attended; desligado -> :excluded" do
        on = instance_double(RegulationRndsSetting, send_external: true)
        off = instance_double(RegulationRndsSetting, send_external: false)
        request = regulation_request!(status: "external")
        offered = offer!(provider: external_provider!)
        result = CareRegulation::ScheduleExternal.call(request: request, at: Time.current.iso8601, place: "Hospital", notes: nil,
                                                       version: request.version, by: regulator, care_provider_id: offered.care_provider_id)
        raise "agendamento recusado: #{result.reason}" if result.failure?

        expect(target(request, on).status).to eq("booked")
        expect(target(request, off)).to eq(:excluded)
        done = CareRegulation::RecordOutcome.call(request: request, result: "completed", version: request.version, by: regulator)
        raise "desfecho recusado: #{done.reason}" if done.failure?

        expect(target(request, on).status).to eq("attended")
        expect(target(request, off)).to eq(:excluded)
      end

      it "cancelled e closed, desligado -> :excluded" do
        off = instance_double(RegulationRndsSetting, send_external: false)
        cancelled = decide!(regulation_request!(status: "external"), "cancel")
        expect(target(cancelled, off)).to eq(:excluded)
        expect(target(cancelled, instance_double(RegulationRndsSetting, send_external: true)).status).to eq("cancelled")

        closed = regulation_request!(status: "external")
        closed.update_columns(status: "closed", misses: 2)
        RegulationRequestEvent.create!(regulation_request: closed, status: "closed", by_user: regulator)
        expect(target(closed, off)).to eq(:excluded)
      end
    end
  end

  describe ".steps" do
    def absence_at(request) = request.events.select { |e| e.status == "missed" }.map { |e| e.created_at.iso8601(6) }

    it "o at do passo leva os microssegundos da linha missed (N1)" do
      travel_to(now + 0.654321.seconds, with_usec: true)
      allow(RegulationRequestEvent).to receive(:create!).and_call_original
      request = miss!(schedule!(reauthorize!(regulation_request!, offer: offer)))
      row = request.events.find { |e| e.status == "missed" }
      expect(row.created_at.usec).to eq(654_321)
      expect(described_class.steps(request, since: nil)).to eq([ { "status" => "absence", "at" => row.created_at.iso8601(6) } ])
      expect(Time.zone.parse(described_class.steps(request, since: nil).first["at"])).to eq(row.created_at)
    end

    it "1ª falta (volta a pending) depois do último aceite -> [absence]" do
      request = schedule!(reauthorize!(regulation_request!, offer: offer))
      since = Time.current
      travel(5.seconds)
      request = miss!(request)
      expect(request.status).to eq("pending")
      expect(described_class.steps(request, since: since)).to eq([ { "status" => "absence", "at" => absence_at(request).last } ])
    end

    it "autorizado -> agendado -> 1ª falta -> pendente -> reautorizado -> agendado, tudo antes do job: [absence] e desejado booked" do
      request = schedule!(reauthorize!(regulation_request!, offer: offer))
      request = miss!(request)
      request = reauthorize!(request, offer: offer)
      request = schedule!(request)
      expect(target(request).status).to eq("booked")
      expect(described_class.steps(request, since: nil)).to eq([ { "status" => "absence", "at" => absence_at(request).sole } ])
    end

    it "a pending intermediária se junta: reautorizada e ainda sem horário, o desejado é pending e o passo continua" do
      request = schedule!(reauthorize!(regulation_request!, offer: offer))
      request = reauthorize!(miss!(request), offer: offer)
      expect(target(request).status).to eq("pending")
      expect(described_class.steps(request, since: nil).map { |s| s["status"] }).to eq(%w[absence])
    end

    it "duas faltas antes do envio: desejado absence e steps == [] (o último passo iguala o desejado)" do
      request = reauthorize!(miss!(schedule!(reauthorize!(regulation_request!, offer: offer))), offer: offer)
      request = miss!(schedule!(request))
      expect(request.status).to eq("closed")
      expect(target(request).status).to eq("absence")
      expect(absence_at(request).size).to eq(2)
      expect(described_class.steps(request, since: nil)).to eq([])
    end

    it "falta anterior ao since não volta" do
      request = schedule!(reauthorize!(regulation_request!, offer: offer))
      request = miss!(request)
      travel(1.minute)
      since = Time.current
      travel(1.minute)
      request = schedule!(reauthorize!(request, offer: offer))
      expect(described_class.steps(request, since: since)).to eq([])
      expect(described_class.steps(request, since: nil).size).to eq(1)
    end

    it "com settings: não lê RegulationRndsSetting.current e os ajustes passados decidem o desejado" do
      request = regulation_request!(status: "external")
      2.times { RegulationRequestEvent.create!(regulation_request: request, status: "missed", by_user: regulator, **slot_columns) }
      RegulationRequestEvent.create!(regulation_request: request, status: "closed", by_user: regulator)
      request.update_columns(status: "closed", misses: 2)
      request.reload
      expect(RegulationRndsSetting).not_to receive(:current)
      on = instance_double(RegulationRndsSetting, send_external: true, specialty_sigtap: {}, priority_by_color: {})
      off = instance_double(RegulationRndsSetting, send_external: false, specialty_sigtap: {}, priority_by_color: {})
      expect(described_class.steps(request, since: nil, settings: on)).to eq([])
      expect(described_class.steps(request, since: nil, settings: off).map { |s| s["status"] }).to eq(%w[absence])
    end

    it "sem falta -> []" do
      expect(described_class.steps(regulation_request!, since: nil)).to eq([])
    end

    it "passos consecutivos iguais viram um" do
      request = regulation_request!
      3.times { RegulationRequestEvent.create!(regulation_request: request, status: "missed", by_user: regulator, **slot_columns) }
      expect(described_class.steps(request.reload, since: nil).size).to eq(1)
    end

    # Q31: a falta sem horário e prestador (anterior à Q24) nunca sai; calculada
    # a cada chamada, sem marcador gravado. A nova (com as colunas) segue.
    it "Q31: falta antiga intermediária é pulada; a nova continua como passo" do
      request = regulation_request!
      old = RegulationRequestEvent.create!(regulation_request: request, status: "missed", by_user: regulator)
      travel(1.minute)
      fresh = RegulationRequestEvent.create!(regulation_request: request, status: "missed", by_user: regulator, **slot_columns)
      steps = described_class.steps(request.reload, since: nil)
      expect(steps).to eq([ { "status" => "absence", "at" => fresh.created_at.iso8601(6) } ])
      expect(steps.first["at"]).not_to eq(old.created_at.iso8601(6))
      expect(described_class.steps(request.reload, since: nil)).to eq(steps) # determinístico: o mesmo resultado a cada cálculo
    end

    it "Q31: só falta antiga → []" do
      request = regulation_request!
      RegulationRequestEvent.create!(regulation_request: request, status: "missed", by_user: regulator)
      expect(described_class.steps(request.reload, since: nil)).to eq([])
    end
  end

  # Revisão final M1: o `closed` → absence/cancelled é uma regra só (RndsStatus e RiraFacts).
  describe ".closed_status" do
    it "MAX_MISSES faltas → absence; menos → cancelled; o RiraFacts usa a mesma regra" do
      max = CareRegulation::Catalog::MAX_MISSES
      expect(described_class.closed_status(Struct.new(:misses).new(max))).to eq("absence")
      expect(described_class.closed_status(Struct.new(:misses).new(max - 1))).to eq("cancelled")
      expect(Rails.root.join("app/services/regulation/rira_facts.rb").read).to include("RndsStatus.closed_status(request)")
      expect(Rails.root.join("app/services/regulation/rira_facts.rb").read).not_to include("MAX_MISSES")
    end
  end
end

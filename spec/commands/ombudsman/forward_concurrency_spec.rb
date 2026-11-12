require "rails_helper"

# Review Focus 1 do plano do 33 (ADR 0051; contrato §2; §16 Q33), na parte
# que a Task 12 já tem: duas técnicas agem na MESMA manifestação ao mesmo
# tempo, as duas com `expected_state: "in_analysis"`. A primeira encaminha e
# fica parada depois de gravar (antes do commit), segurando a manifestação
# (Ombudsman::Lock, FOR UPDATE); a segunda espera a trava e, solta a
# primeira, relê `forwarded` e recebe 409 manifestation_changed — nada dela é
# gravado (nem encaminhamento, nem evento, nem ombudsman.forwarded). O par
# `final_response` × `forward` entra na Task 13 (preflight F-19), com o
# comando que ainda não existe.
#
# O mesmo vale para o encaminhamento (Q33): a resposta do respondente e o
# cancelamento da equipe sobre o MESMO encaminhamento travam manifestação →
# encaminhamento, na mesma ordem; quem chega depois recebe 409
# forwarding_changed e não grava nada. Nunca deadlock.
#
# Threads reais contra TEST_CITY_A (sem fixture transacional), no padrão do
# módulo 09 (spec/models/health_unit_lock_spec.rb): pop(timeout:), e o after
# solta as threads e apaga tudo o que commitou.
RSpec.describe "Ombudsman — duas ações na mesma manifestação" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:extract) { "Extrato do caso enviado ao mesmo tempo por duas técnicas." }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def user!(tag, role)
    User.create!(email_address: "#{role}-#{tag}@cidade.gov.br", password: "senha-segura-123").tap do |user|
      Membership.create!(user: user, role: role, granted_at: Time.current)
      (ids[:users] ||= []) << user.id
    end
  end

  before do
    in_city do
      Ombudsman::Settings.ensure_defaults!
      tag = SecureRandom.hex(4)
      admin = user!(tag, "municipal_admin")
      ids[:first] = user!("#{tag}-a", "ombudsman_staff").id
      ids[:second] = user!("#{tag}-b", "ombudsman_staff").id
      ids[:responder] = user!(tag, "ombudsman_responder").id
      ids[:department] = Department.create!(name: "Setor Corrida #{tag}", updated_by_user: admin).id
      ids[:unit] = HealthUnit.create!(name: "UBS Corrida #{tag}", kind: "ubs").id
      ids[:responders] = [
        OmbudsmanResponder.create!(user_id: ids[:responder], department_id: ids[:department], created_by_user: admin).id,
        OmbudsmanResponder.create!(user_id: ids[:responder], health_unit_id: ids[:unit], created_by_user: admin).id
      ]
      now = Time.current
      ids[:manifestation] = OmbudsmanManifestation.create!(
        protocol: OmbudsmanManifestation.next_protocol(now), kind: "complaint", identification_mode: "identified", channel: "phone",
        created_by_user_id: ids[:first], body: OmbudsmanHelpers::BODY, state: "in_analysis", received_at: now,
        cycle_started_on: now.in_time_zone.to_date
      ).id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError, ScriptError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where("payload->>'manifestation_id' = ?", ids[:manifestation].to_s).delete_all
        OmbudsmanEvent.where(ombudsman_manifestation_id: ids[:manifestation]).delete_all
        OmbudsmanForwarding.where(ombudsman_manifestation_id: ids[:manifestation]).delete_all
        OmbudsmanManifestation.where(id: ids[:manifestation]).delete_all
        OmbudsmanResponder.where(id: ids[:responders]).delete_all
        Department.where(id: ids[:department]).delete_all
        HealthUnit.where(id: ids[:unit]).delete_all
        Session.where(user_id: ids[:users]).delete_all
        Membership.where(user_id: ids[:users]).delete_all
        User.where(id: ids[:users]).delete_all
      end
    end
  end

  # A exceção da thread (deadlock inclusive) volta como valor, para o expect.
  def capture
    yield
  rescue StandardError => e
    e
  end

  def forward(user_key, destination)
    capture do
      in_city do
        Ombudsman::Forward.call(manifestation_id: ids[:manifestation], expected_state: "in_analysis",
                                department_id: (ids[:department] if destination == :department),
                                health_unit_id: (ids[:unit] if destination == :unit), extract: extract, by: User.find(ids[user_key]))
      end
    end
  end

  def reply
    capture do
      in_city do
        Ombudsman::ReplyForwarding.call(forwarding_id: ids[:forwarding], expected_state: "pending",
                                        body: "Resposta do setor ao encaminhamento.", by: User.find(ids[:responder]))
      end
    end
  end

  def cancel
    capture do
      in_city do
        Ombudsman::CancelForwarding.call(forwarding_id: ids[:forwarding], expected_state: "pending", reason: nil,
                                         by: User.find(ids[:second]))
      end
    end
  end

  # A primeira grava, publica `event` e fica parada antes do commit; a
  # segunda tem de esperar na trava da manifestação.
  # -> [resultado da primeira, resultado da segunda]
  def race(event, first, second)
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == event
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << first.call })
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    second_result = Queue.new
    threads << other = Thread.new { second_result << second.call }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera na trava da manifestação

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results).to all(be_a(Result)) # nenhuma exceção (PG::TRDeadlockDetected inclusive)
    results
  end

  it "dois forward com expected_state in_analysis: um vence, o outro 409 manifestation_changed e nada dele é gravado" do
    first, second = race("ombudsman.forwarded", -> { forward(:first, :department) }, -> { forward(:second, :unit) })
    expect(first).to be_ok
    expect(second.reason).to eq(:manifestation_changed)

    in_city do
      expect(OmbudsmanManifestation.find(ids[:manifestation]).state).to eq("forwarded")
      forwarding = OmbudsmanForwarding.where(ombudsman_manifestation_id: ids[:manifestation]).sole
      expect(forwarding).to have_attributes(department_id: ids[:department], created_by_user_id: ids[:first])
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: ids[:manifestation]).pluck(:kind, :actor_user_id))
        .to eq([ [ "forwarded", ids[:first] ] ])
      expect(DomainEvent.where(name: "ombudsman.forwarded").where("payload->>'manifestation_id' = ?", ids[:manifestation].to_s).count)
        .to eq(1)
    end
  end

  it "resposta do respondente × cancelamento do mesmo encaminhamento: a resposta vence, o cancelamento 409 forwarding_changed sem gravar" do
    in_city do
      forwarded = Ombudsman::Forward.call(manifestation_id: ids[:manifestation], expected_state: "in_analysis",
                                          department_id: ids[:department], health_unit_id: nil, extract: extract,
                                          by: User.find(ids[:first]))
      raise "encaminhamento recusado: #{forwarded.reason}" if forwarded.failure?

      ids[:forwarding] = forwarded.payload.fetch(:forwarding).id
    end

    replied, cancelled = race("ombudsman.forwarding_replied", -> { reply }, -> { cancel })
    expect(replied).to be_ok
    expect(cancelled.reason).to eq(:forwarding_changed)

    in_city do
      expect(OmbudsmanForwarding.find(ids[:forwarding]).state).to eq("replied")
      expect(OmbudsmanManifestation.find(ids[:manifestation]).state).to eq("in_analysis")
      expect(OmbudsmanEvent.where(ombudsman_manifestation_id: ids[:manifestation]).order(:created_at, :id).pluck(:kind))
        .to eq(%w[forwarded forwarding_replied])
    end
  end
end

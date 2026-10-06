require "rails_helper"

# Exclusão do cadastro × esvaziamento da unidade (revisão final, Important 1).
# Citizens::Erase trava os pares do CPF em FOR UPDATE (de propósito: segura a
# FK de um atendimento novo enquanto reconfere a retenção) e escreve pedidos
# (a nota do remarque e o CloseRevoked). HealthUnits::Drain trava unidade →
# horários → pedidos e grava o pedido novo, cuja FK pega KEY SHARE no cidadão.
# Sem a unidade na frente, os dois cruzavam (ActiveRecord::Deadlocked): Erase
# segurava o cidadão e esperava o pedido; Drain segurava o pedido e esperava o
# cidadão. Threads reais contra TEST_CITY_A, como
# spec/commands/appointments/book_drain_concurrency_spec.rb.
RSpec.describe Citizens::Erase, "concorrência com Drain" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  before do
    in_city do
      ids[:started_at] = Time.current
      ids[:types] = Scheduling::AppointmentTypes.seed_platform!.positive?
      tag = SecureRandom.hex(4)
      ids[:admin] = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:verifier] = User.create!(email_address: "ver-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:unit] = HealthUnit.create!(name: "UBS Fecha #{tag}", kind: "ubs").id
      ids[:dest] = HealthUnit.create!(name: "UBS Destino #{tag}", kind: "ubs").id
      protocol = ProtocolDefinition.create!(name: "erase-#{tag}", version: 1, status: "draft",
                                            definition: default_protocol_definition("erase-#{tag}"))
      ids[:protocol] = protocol.id
      cpf = CampaignHistory.cpf_for("erase-#{tag}")
      citizen = Citizen.create!(cpf: cpf, phone: "+55419#{format('%08d', 50_000_000 + SecureRandom.random_number(1_000_000))}")
      ids[:citizen] = citizen.id
      conversation = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
      ids[:conversation] = conversation.id
      Consent.create!(conversation: conversation, version: 1, policy_text_sha: "sha", channel: "web",
                      given_at: 1.hour.ago)
      triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                              status: "completed", tier: "alta", priority: 1, answers: {}, completed_at: Time.current)
      ids[:triage] = triage.id
      # Todo pedido gerado pela triagem nasce aberto: o CloseRevoked da exclusão o trava.
      ids[:request] = AppointmentRequest.create!(kind: "triage", origin_triage: triage, root_triage: triage,
                                                 citizen: citizen, target_unit_id: ids[:unit],
                                                 appointment_type_key: "consulta_medica",
                                                 reschedule_note: "Só depois das 14h").id
      ids[:erasure] = CitizenErasureRequest.create!(cpf: cpf, presented_citizen: citizen,
                                                    requested_by_user_id: ids[:verifier],
                                                    document_checked: true, status: "pending").id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where(created_at: ids[:started_at]..).delete_all if ids[:started_at]
        HealthUnitDrain.where(health_unit_id: ids.values_at(:unit, :dest).compact).delete_all
        request_ids = AppointmentRequest.where(citizen_id: ids[:citizen]).pluck(:id)
        AppointmentRequestTriage.where(request_id: request_ids).delete_all
        AppointmentRequest.where(id: request_ids).delete_all
        CitizenErasureRequest.where(id: ids[:erasure]).delete_all
        Triage.where(id: ids[:triage]).delete_all
        Consent.where(conversation_id: ids[:conversation]).delete_all
        Conversation.where(id: ids[:conversation]).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
        HealthUnit.where(id: ids[:dest]).delete_all
        User.where(id: ids[:verifier]).delete_all
        AppointmentType.where(origin: "platform").delete_all if ids[:types]
      end
    end
    purge_committed_rows(ids)
  end

  def default_protocol_definition(name)
    { "name" => name, "version" => 1, "start_step_id" => "tosse",
      "steps" => [ { "id" => "tosse", "prompt" => "Você está com tosse?", "answer_type" => "boolean",
                     "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 1 } } }
  end

  # Exceção (ex.: ActiveRecord::Deadlocked) vira o valor devolvido, para o
  # exemplo afirmar sobre ela em vez de perdê-la dentro da thread.
  def capture
    yield
  rescue StandardError => e
    e
  end

  def erase
    capture do
      in_city { described_class.call(request: CitizenErasureRequest.find(ids[:erasure]), by: User.find(ids[:admin])) }
    end
  end

  def drain
    capture do
      in_city do
        HealthUnits::Drain.call(unit: HealthUnit.find(ids[:unit]), target_unit_id: ids[:dest],
                                reason: "unidade fechada para reforma", by: User.find(ids[:admin]))
      end
    end
  end

  def requests = in_city { AppointmentRequest.where(citizen_id: ids[:citizen]).order(:created_at, :id).to_a }

  it "exclusão já com o cidadão travado, esvaziamento chega: o Drain espera a unidade, sem deadlock" do
    holding = Queue.new
    holder = nil
    allow(described_class).to receive(:erase_pair).and_wrap_original do |original, *args|
      if Thread.current == holder
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      original.call(*args)
    end

    erase_result = Queue.new
    threads << (holder = Thread.new { erase_result << erase })
    holding.pop(timeout: 5) or raise "a exclusão não chegou às travas"

    drain_result = Queue.new
    threads << drainer = Thread.new { drain_result << drain }
    expect(in_city { wait_for_lock_wait }).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(drainer.join(10)).to be(drainer)
    erased = erase_result.pop(timeout: 1)
    drained = drain_result.pop(timeout: 1)
    expect(erased).to be_a(Result).and be_ok
    expect(drained).to be_a(Result).and be_ok
    # A exclusão fechou o pedido antes; o esvaziamento não tinha mais o que mover.
    expect(drained.payload).to include(requests: 0)
    expect(requests.map { |r| [ r.id, r.status, r.closed_reason, r.reschedule_note ] })
      .to eq([ [ ids[:request], "closed", "consent_revoked", nil ] ])
  end

  it "esvaziamento já com as travas, exclusão chega: a exclusão espera e fecha o pedido já movido" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "health_unit.drained"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    drain_result = Queue.new
    threads << (holder = Thread.new { drain_result << drain })
    holding.pop(timeout: 5) or raise "o esvaziamento não chegou às travas"

    erase_result = Queue.new
    threads << eraser = Thread.new { erase_result << erase }
    expect(in_city { wait_for_lock_wait }).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(eraser.join(10)).to be(eraser)
    expect(drain_result.pop(timeout: 1)).to be_a(Result).and be_ok
    expect(erase_result.pop(timeout: 1)).to be_a(Result).and be_ok
    # O pedido movido herda o created_at do antigo: separa pela ligação, não pela ordem.
    fresh, old = requests.partition(&:moved_from_request_id)
    expect([ old.size, fresh.size ]).to eq([ 1, 1 ])
    old = old.sole
    fresh = fresh.sole
    expect(old).to have_attributes(id: ids[:request], status: "closed", closed_reason: "moved", reschedule_note: nil)
    expect(fresh).to have_attributes(moved_from_request_id: ids[:request], target_unit_id: ids[:dest], status: "closed", closed_reason: "consent_revoked",
                                     reschedule_note: nil)
  end
end

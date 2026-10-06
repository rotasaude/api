require "rails_helper"

# Conclusão da triagem (Triages::Schedule) × esvaziamento da mesma unidade
# (revisão da Task 14). SubmitAnswer trava o cidadão e o Schedule roda sob essa
# trava; o Drain trava a unidade (FOR UPDATE) → pedidos e grava o pedido novo,
# cuja FK pega FOR KEY SHARE no cidadão. Com o cidadão em FOR UPDATE os dois
# cruzavam (ActiveRecord::Deadlocked): o insert do Schedule esperava a unidade
# (FK) ou o pedido vivo (fusão), e o Drain esperava o cidadão. Com FOR NO KEY
# UPDATE (como Placement.lock!) o Drain não espera a trava do cidadão. Threads
# reais contra TEST_CITY_A, como spec/commands/appointments/book_drain_concurrency_spec.rb.
RSpec.describe Triages::Schedule, "concorrência com Drain" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def setup!(live_type:)
    in_city do
      ids[:started_at] = Time.current
      ids[:types] = Scheduling::AppointmentTypes.seed_platform!.positive?
      tag = SecureRandom.hex(4)
      ids[:admin] = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123").id
      ids[:unit] = HealthUnit.create!(name: "UBS Fecha #{tag}", kind: "ubs").id
      ids[:dest] = HealthUnit.create!(name: "UBS Destino #{tag}", kind: "ubs").id
      ids[:neighborhood] = Neighborhood.create!(name: "Bairro #{tag}", source: "seed").id
      NeighborhoodCoverage.create!(neighborhood_id: ids[:neighborhood], health_unit_id: ids[:unit])
      rule = { "when" => { "gte" => [ "outcome.score", 4 ] }, "appointment_type" => "consulta_medica",
               "priority" => "priority", "due_in_days" => 7 }
      ids[:protocol] = active_protocol!("corrida-#{tag}", scheduling: [ rule ]).id
      citizen = Citizen.create!(cpf: CampaignHistory.cpf_for("sched-#{tag}"),
                                phone: "+55419#{format('%08d', 40_000_000 + SecureRandom.random_number(1_000_000))}",
                                birth_date: birth_date_for(70), sex: "female", profile_source: "declared",
                                neighborhood_id: ids[:neighborhood])
      ids[:citizen] = citizen.id
      # Pedido vivo do cidadão na unidade que esvazia (o Drain o move).
      old = Conversation.create!(channel: "web", citizen: citizen, phone: citizen.phone, state: "completed")
      old_triage = Triage.create!(conversation: old, protocol_definition_id: ids[:protocol],
                                  protocol_name: "corrida-#{tag}", status: "completed", tier: "media", priority: 5,
                                  answers: { "q1" => "true" }, completed_at: Time.current)
      ids[:request] = AppointmentRequest.create!(kind: "triage", origin_triage: old_triage, root_triage: old_triage,
                                                 citizen: citizen, target_unit_id: ids[:unit],
                                                 appointment_type_key: live_type).id
      started = start_for!(citizen, "corrida-#{tag}").payload
      ids[:conversation] = started[:conversation].id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where(created_at: ids[:started_at]..).delete_all if ids[:started_at]
        HealthUnitDrain.where(health_unit_id: ids.values_at(:unit, :dest).compact).delete_all
        request_ids = AppointmentRequest.where(citizen_id: ids[:citizen]).pluck(:id)
        AppointmentRequestTriage.where(request_id: request_ids).delete_all
        AppointmentRequest.where(id: request_ids).delete_all
        conversation_ids = Conversation.where(citizen_id: ids[:citizen]).pluck(:id)
        triage_ids = Triage.where(conversation_id: conversation_ids).pluck(:id)
        ReportSnapshot.where(triage_id: triage_ids).delete_all
        TriageSuggestion.where(citizen_id: ids[:citizen]).delete_all
        Triage.where(id: triage_ids).delete_all
        Consent.where(conversation_id: conversation_ids).delete_all
        Conversation.where(id: conversation_ids).delete_all
        Citizen.where(id: ids[:citizen]).delete_all
        NeighborhoodCoverage.where(neighborhood_id: ids[:neighborhood]).delete_all
        Neighborhood.where(id: ids[:neighborhood]).delete_all
        ProtocolDefinition.where(id: ids[:protocol]).delete_all
        HealthUnit.where(id: ids[:dest]).delete_all
        AppointmentType.where(origin: "platform").delete_all if ids[:types]
      end
    end
    purge_committed_rows(ids)
    Rails.cache.clear
  end

  def capture
    yield
  rescue StandardError => e
    e
  end

  def submit
    capture do
      in_city do
        Citizens::SubmitAnswer.call(conversation: Conversation.find(ids[:conversation]), answer: "true",
                                    idempotency_key: SecureRandom.uuid)
      end
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

  # A conclusão para no Schedule (cidadão já travado); o Drain corre inteiro
  # sem esperar o cidadão; depois a conclusão segue.
  def race!
    holding = Queue.new
    holder = nil
    allow(described_class).to receive(:call).and_wrap_original do |original, **kwargs|
      if Thread.current == holder
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      original.call(**kwargs)
    end

    submit_result = Queue.new
    threads << (holder = Thread.new { submit_result << submit })
    holding.pop(timeout: 5) or raise "a conclusão não chegou ao Schedule"

    drain_result = Queue.new
    threads << drainer = Thread.new { drain_result << drain }
    drained_alone = drainer.join(5)
    release << true
    expect(holder.join(10)).to be(holder)
    expect(drainer.join(10)).to be(drainer)
    @drained_alone = drained_alone == drainer # o Drain não esperou a trava do cidadão
    [ submit_result.pop(timeout: 1), drain_result.pop(timeout: 1) ]
  end

  def live_requests = in_city { AppointmentRequest.live_requests.where(citizen_id: ids[:citizen]).to_a }

  it "pedido novo na unidade que esvazia: sem deadlock; o Drain move o pedido antigo e o novo nasce depois" do
    setup!(live_type: "consulta_enfermagem")
    submitted, drained = race!
    expect(submitted).to be_a(Result).and be_ok
    expect(drained).to be_a(Result).and be_ok
    expect(drained.payload).to include(requests: 1)
    expect(live_requests.map { |r| [ r.appointment_type_key, r.target_unit_id ] })
      .to contain_exactly([ "consulta_enfermagem", ids[:dest] ], [ "consulta_medica", ids[:unit] ])
    expect(@drained_alone).to be(true)
  end

  it "fusão com o pedido que o Drain move: sem deadlock; a triagem cai no pedido já movido" do
    setup!(live_type: "consulta_medica")
    submitted, drained = race!
    expect(submitted).to be_a(Result).and be_ok
    expect(drained).to be_a(Result).and be_ok
    request = live_requests.sole
    expect(request).to have_attributes(target_unit_id: ids[:dest], moved_from_request_id: ids[:request],
                                       priority: "priority")
    expect(in_city { request.request_triages.pluck(:triage_id) })
      .to eq([ submitted.payload[:triage].id ])
    expect(@drained_alone).to be(true)
  end
end

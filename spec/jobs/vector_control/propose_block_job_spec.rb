require "rails_helper"

# Módulo 35a, Task 11 (ADR 0054; contrato §8, §17; Q8, Q13(6)): o consumidor
# de disease_notification.created e .transitioned propõe o bloqueio de
# transmissão. Só a notificação `notified` de doença em block_diseases, com o
# gate utilizável. O caso entra no bloqueio proposed/active cuja área tem o
# quarteirão dele (a proposta conta os anéis do centro) e com caso recente na
# janela; senão nasce a proposta. Sem lugar: proposta própria e tarefa; caso
# de fora: só a tarefa. Eventos só com ids.
RSpec.describe VectorControl::ProposeBlockJob, type: :job do
  let!(:city) { block_city! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:center) { city_block!(neighborhood: neighborhood, number: "10") }
  let(:neighbor) { city_block!(neighborhood: neighborhood, number: "11") }
  let(:far) { city_block!(neighborhood: neighborhood, number: "30") }
  let(:side) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:today) { Time.zone.today }

  before { block_neighbors!(center, neighbor) }
  after { Current.reset }

  def case_of(notification) = TransmissionBlockCase.find_by(disease_notification_id: notification.id)

  it "dengue notified com quarteirão → proposta com centro e área de 1 anel" do
    notification = arbovirus_case!(patient: block_case_patient!(block: center))
    propose_from!("disease_notification.created", notification)

    row = case_of(notification)
    block = row.transmission_block
    expect(block).to have_attributes(status: "proposed", disease_group: "arbovirus", center_block_id: center.id)
    expect(row).to have_attributes(added_by: "job", case_on: notification.suspected_on, number: 1)
    expect(TransmissionBlockArea.where(transmission_block_id: block.id)).to be_empty # a proposta só sugere
    json = VectorControl::Json.transmission_block(block)
    expect(json[:area]).to eq([ { id: center.id, number: "10", suggested: true }, { id: neighbor.id, number: "11", suggested: true } ])
    expect(json[:cases]).to eq([ { id: row.id, number: 1, disease: "dengue", case_on: notification.suspected_on.iso8601, has_place: true } ])
    expect(DomainEvent.where(name: "transmission_block.proposed").map(&:payload)).to eq([ { "transmission_block_id" => block.id } ])
    expect(VectorTask.count).to eq(0)
  end

  it "caso no 7º dia no quarteirão vizinho → mesmo bloqueio; ativo pela área confirmada" do
    first = proposed_case!(patient: block_case_patient!(block: center), on: today - 7)
    second = proposed_case!(patient: block_case_patient!(block: neighbor), on: today)

    expect(second.transmission_block_id).to eq(first.transmission_block_id)
    expect([ first.number, second.number ]).to eq([ 1, 2 ])
    expect(DomainEvent.where(name: "transmission_block.proposed").count).to eq(1)

    block = first.transmission_block
    coordinator = endemic_coordinator!
    block_neighbors!(center, side)
    expect(VectorControl::Blocks::Confirm.call(block: block, center_block_id: center.id, block_ids: [ neighbor.id, far.id ], by: coordinator)).to be_ok
    third = proposed_case!(patient: block_case_patient!(block: far), on: today)
    expect(third.transmission_block_id).to eq(block.id) # a área do ativo é a confirmada
    outside = proposed_case!(patient: block_case_patient!(block: side), on: today)
    expect(outside.transmission_block_id).not_to eq(block.id) # vizinho do centro fora da área confirmada
  end

  it "caso no 8º dia no mesmo quarteirão → nova proposta" do
    first = proposed_case!(patient: block_case_patient!(block: center), on: today - 8)
    second = proposed_case!(patient: block_case_patient!(block: center), on: today)

    expect(second.transmission_block_id).not_to eq(first.transmission_block_id)
    expect(second.transmission_block).to have_attributes(status: "proposed", center_block_id: center.id)
    expect(DomainEvent.where(name: "transmission_block.proposed").count).to eq(2)
  end

  it "caso longe do quarteirão → nova proposta" do
    first = proposed_case!(patient: block_case_patient!(block: center))
    second = proposed_case!(patient: block_case_patient!(block: far))
    expect(second.transmission_block_id).not_to eq(first.transmission_block_id)
  end

  it "possible não age; ao passar a notified, age" do
    notification = arbovirus_case!(patient: block_case_patient!(block: center), origin: "safety_net")
    expect(notification.status).to eq("possible")
    propose_from!("disease_notification.created", notification)
    expect(case_of(notification)).to be_nil

    result = Surveillance::Transition.call(notification: notification, to: "notified", version: notification.reload.version,
                                           by: surveillance_officer!)
    expect(result).to be_ok
    propose_from!("disease_notification.transitioned", notification)
    expect(case_of(notification).transmission_block).to have_attributes(status: "proposed", center_block_id: center.id)
  end

  # Q26(1): a fila pode atrasar; quem já está em investigação ainda chegou a notified.
  it "notificação já em investigating: o created atrasado propõe; a reentrega não duplica" do
    notification = arbovirus_case!(patient: block_case_patient!(block: center))
    officer = surveillance_officer!
    expect(Surveillance::Transition.call(notification: notification, to: "investigating", version: notification.reload.version,
                                         by: officer)).to be_ok
    expect(notification.reload.status).to eq("investigating")

    2.times { propose_from!("disease_notification.created", notification) }
    expect(case_of(notification).transmission_block).to have_attributes(status: "proposed", center_block_id: center.id)
    expect(TransmissionBlockCase.where(disease_notification_id: notification.id).count).to eq(1)
    propose_from!("disease_notification.transitioned", notification)
    expect(TransmissionBlockCase.count).to eq(1)
    expect(DomainEvent.where(name: "transmission_block.proposed").count).to eq(1)
  end

  it "o transitioned para investigating propõe; closed não age" do
    notification = arbovirus_case!(patient: block_case_patient!(block: center), origin: "safety_net")
    officer = surveillance_officer!
    %w[notified investigating].each do |to|
      expect(Surveillance::Transition.call(notification: notification, to: to, version: notification.reload.version, by: officer)).to be_ok
    end
    propose_from!("disease_notification.transitioned", notification) # o último: notified → investigating
    propose_from!("disease_notification.transitioned", notification)
    expect(TransmissionBlockCase.where(disease_notification_id: notification.id).count).to eq(1)

    closed = arbovirus_case!(patient: block_case_patient!(block: center))
    expect(Surveillance::Transition.call(notification: closed, to: "investigating", version: closed.reload.version, by: officer)).to be_ok
    expect(Surveillance::Transition.call(notification: closed, to: "closed", version: closed.reload.version, by: officer,
                                         classification: "confirmed")).to be_ok
    propose_from!("disease_notification.created", closed)
    propose_from!("disease_notification.transitioned", closed)
    expect(case_of(closed)).to be_nil
  end

  it "a sugestão deixa de fora o quarteirão inativo" do
    row = proposed_case!(patient: block_case_patient!(block: center))
    neighbor.update!(active: false)
    expect(VectorControl::Json.transmission_block(row.transmission_block)[:area]).to eq([ { id: center.id, number: "10", suggested: true } ])
    center.update!(active: false)
    expect(VectorControl::Json.transmission_block(row.transmission_block)).to include(center_block: { id: center.id, number: "10" }, area: [])
  end

  it "doença fora de block_diseases ou gate desligado → nada" do
    other = arbovirus_case!(patient: block_case_patient!(block: center), disease_code: "sarampo")
    propose_from!("disease_notification.created", other)
    liraa_parameters!(block_diseases: %w[zika])
    dengue = arbovirus_case!(patient: block_case_patient!(block: center))
    propose_from!("disease_notification.created", dengue)
    expect(TransmissionBlockCase.count).to eq(0)

    liraa_parameters!(block_diseases: %w[dengue])
    off = arbovirus_case!(patient: block_case_patient!(block: center))
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    propose_from!("disease_notification.created", off)
    expect(TransmissionBlockCase.count).to eq(0)
    expect(TransmissionBlock.count).to eq(0)
  end

  it "resident_elsewhere → só a tarefa" do
    notification = arbovirus_case!(patient: block_case_patient!(block: center), resident_elsewhere: true, residence_ibge: "4113700")
    propose_from!("disease_notification.created", notification)
    propose_from!("disease_notification.created", notification) # o mesmo evento de novo: nada

    expect(TransmissionBlock.count).to eq(0)
    task = VectorTask.sole
    expect(task).to have_attributes(kind: "case_resident_elsewhere", disease_notification_id: notification.id, state: "open")
    expect(DomainEvent.where(name: "vector_task.opened").map(&:payload)).to eq([ { "vector_task_id" => task.id } ])
  end

  it "sem cadastro ativo → proposta sem centro e tarefa block_case_without_place" do
    notification = arbovirus_case!(patient: registry_patient!)
    propose_from!("disease_notification.created", notification)
    without_profile = arbovirus_case!(patient: block_case_patient!)
    propose_from!("disease_notification.created", without_profile)

    blocks = [ case_of(notification), case_of(without_profile) ].map(&:transmission_block)
    expect(blocks.uniq.size).to eq(2) # sem lugar: sempre proposta própria
    expect(blocks).to all(have_attributes(status: "proposed", center_block_id: nil))
    tasks = VectorTask.order(:created_at).to_a
    expect(tasks.map { |task| [ task.kind, task.transmission_block_id ] })
      .to eq(blocks.map { |block| [ "block_case_without_place", block.id ] })
    json = VectorControl::Json.transmission_block(blocks.first)
    expect(json).to include(center_block: nil, area: [])
    expect(json[:cases].sole).to include(has_place: false)
  end

  it "o mesmo evento duas vezes → um caso só; o caso já em bloqueio não muda" do
    notification = arbovirus_case!(patient: block_case_patient!(block: center))
    2.times { propose_from!("disease_notification.created", notification) }
    expect(TransmissionBlockCase.where(disease_notification_id: notification.id).count).to eq(1)

    again = VectorControl::Blocks::Propose.call(notification: notification, parameters: VectorControl::Parameters.current.values)
    expect(again).to be_ok
    expect(TransmissionBlockCase.count).to eq(1)
    expect(TransmissionBlock.count).to eq(1)
  end
end

# Review Focus 3 com threads reais (o molde do liraa/items_spec): dois casos
# de dengue vizinhos notificados ao mesmo tempo. A proposta é serializada pela
# trava consultiva; o segundo espera, vê a proposta do primeiro e entra nela.
# Nunca duas propostas para a mesma área na janela. Contra TEST_CITY_A, sem
# fixture transacional.
RSpec.describe VectorControl::Blocks::Propose, "× duas notificações vizinhas ao mesmo tempo", type: :job do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def snapshot
    connection = ApplicationRecord.connection
    connection.tables.select { |table| connection.column_exists?(table, :id) }
              .to_h { |table| [ table, connection.select_values("SELECT id::text FROM #{connection.quote_table_name(table)}").to_set ] }
  end

  before do
    allow(Ledi::DeliverJob).to receive(:perform_later)
    @before = in_city { snapshot }
    @ids = in_city do
      neighborhood = Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual")
      one = city_block!(neighborhood: neighborhood, number: "1")
      two = city_block!(neighborhood: neighborhood, number: "2")
      block_neighbors!(one, two)
      area = registry_micro_area!(code: "01")
      unit = area.team.health_unit
      notifications = [ one, two ].map do |block|
        patient = registry_patient!
        household = registry_household_rows!(area)
        registry_registration_rows!(patient, household)
        vector_profile!(household, block: block)
        DiseaseNotification.create!(patient: patient, health_unit: unit, disease_code: "dengue", deadline: "weekly", origin: "manual",
                                    status: "notified", suspected_on: Time.zone.today, due_at: 7.days.from_now, form: {})
      end
      { notifications: notifications.map(&:id) }
    end
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        snapshot.each do |table, ids|
          fresh = ids - @before.fetch(table, Set.new)
          next if fresh.empty?

          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id::text IN (#{fresh.map { connection.quote(_1) }.join(',')})")
        end
      end
    end
  end

  def propose(notification_id)
    in_city do
      ApplicationRecord.transaction do
        described_class.call(notification: DiseaseNotification.find(notification_id), parameters: VectorControl::Parameters.current.values)
      end
    end
  end

  def run_now(go, notification_id)
    go.pop(timeout: 5) or raise "timeout esperando go"
    propose(notification_id)
  rescue StandardError => e
    e
  end

  it "duas notificações vizinhas em threads → um bloqueio com dois casos" do
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "transmission_block.proposed"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_id, second_id = @ids[:notifications]
    go_first = Queue.new
    first_result = Queue.new
    threads << (holder = Thread.new { first_result << run_now(go_first, first_id) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a propor"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << run_now(go_second, second_id) })
    go_second << true
    expect(wait_for_lock_wait).to be(true) # a segunda parada na trava consultiva
    expect(other.join(0.3)).to be_nil

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]

    expect(results).to all(be_a(Result)) # nenhuma exceção (deadlock, único)
    expect(results).to all(be_ok)
    in_city do
      cases = TransmissionBlockCase.where(disease_notification_id: @ids[:notifications]).order(:number).to_a
      expect(cases.map(&:transmission_block_id).uniq.size).to eq(1)
      expect(cases.map(&:number).each_cons(2).map { |a, b| b - a }).to eq([ 1 ])
      expect(TransmissionBlock.where(id: cases.first.transmission_block_id).sole.status).to eq("proposed")
      expect(DomainEvent.where(name: "transmission_block.proposed")
                        .where("payload->>'transmission_block_id' = ?", cases.first.transmission_block_id).count).to eq(1)
    end
  end
end

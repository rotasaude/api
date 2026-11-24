require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6, Q21): a etiqueta da coleta de
# sorologia, feita pelo api: LV-<ano>-<6 primeiros hex do id do inquérito, em
# maiúsculas>-<seq>, ou LV-<ano>-AVUL-<seq> fora de inquérito; a seq tem ao
# menos 4 dígitos com zeros à esquerda e cresce até 6, sem recomeçar (Q36). A
# sequência é por prefixo (inquérito e ano, ou o ano avulso), sob
# pg_advisory_xact_lock.
RSpec.describe Zoonoses::Label, type: :model do
  let!(:city) { zoonoses_city! }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:today) { Time.zone.today }

  def collect!(survey, label) = LeishTest.create!(leish_survey: survey, animal: animal!, collected_on: today, label: label)

  it "avulsa → LV-2026-AVUL-0001, depois 0002; o ano avulso tem a sua sequência" do
    first = described_class.next!(survey: nil, year: 2026)
    expect(first).to eq("LV-2026-AVUL-0001")
    collect!(nil, first)
    expect(described_class.next!(survey: nil, year: 2026)).to eq("LV-2026-AVUL-0002")
    expect(described_class.next!(survey: nil, year: 2025)).to eq("LV-2025-AVUL-0001")
  end

  it "o trecho do id sai em maiúsculas e casa o Catalog::LABEL; cada inquérito tem a sua sequência" do
    survey = leish_survey!(blocks: [ block ], id: "abcdef12-3456-4789-8abc-def012345678")
    label = described_class.next!(survey: survey, year: 2026)
    expect(label).to eq("LV-2026-ABCDEF-0001")
    expect(label).to match(Zoonoses::Catalog::LABEL)
    collect!(survey, label)
    collect!(survey, described_class.next!(survey: survey, year: 2026))
    expect(described_class.next!(survey: survey, year: 2026)).to eq("LV-2026-ABCDEF-0003")

    other = leish_survey!(blocks: [ block ], id: "0a1b2c3d-3456-4789-8abc-def012345678")
    expect(described_class.next!(survey: other, year: 2026)).to eq("LV-2026-0A1B2C-0001")
    expect(described_class.next!(survey: nil, year: 2026)).to eq("LV-2026-AVUL-0001")
  end

  it "Q36: a seq é a maior pelo sufixo NUMÉRICO e cresce de 4 até 6 dígitos sem recomeçar; passar de 999999 → Label::Exhausted" do
    collect!(nil, "LV-2026-AVUL-0010")
    collect!(nil, "LV-2026-AVUL-0002")
    expect(described_class.next!(survey: nil, year: 2026)).to eq("LV-2026-AVUL-0011")
    collect!(nil, "LV-2026-AVUL-9999")
    tenth_thousand = described_class.next!(survey: nil, year: 2026)
    expect(tenth_thousand).to eq("LV-2026-AVUL-10000")
    expect(tenth_thousand).to match(Zoonoses::Catalog::LABEL)
    collect!(nil, tenth_thousand)
    # Numérico: -10000 > -9999 (o máximo léxico seria -9999 e repetiria -10000).
    expect(described_class.next!(survey: nil, year: 2026)).to eq("LV-2026-AVUL-10001")
    collect!(nil, "LV-2026-AVUL-999999")
    expect("LV-2026-AVUL-999999").to match(Zoonoses::Catalog::LABEL)
    expect("LV-2026-AVUL-1000000").not_to match(Zoonoses::Catalog::LABEL)
    expect("LV-2026-AVUL-001").not_to match(Zoonoses::Catalog::LABEL)
    expect { described_class.next!(survey: nil, year: 2026) }.to raise_error(Zoonoses::Label::Exhausted)
    expect(described_class.next!(survey: nil, year: 2027)).to eq("LV-2027-AVUL-0001")
  end

  it "fora de transação → ArgumentError (a trava é da transação)" do
    allow(ApplicationRecord.connection).to receive(:transaction_open?).and_return(false)
    expect { described_class.next!(survey: nil, year: 2026) }.to raise_error(ArgumentError)
  end
end

# Duas coletas do mesmo inquérito ao mesmo tempo: a primeira pega a trava,
# grava a etiqueta e fica parada antes do commit; a segunda espera na trava e,
# solta a primeira, sai com a seq seguinte. Threads reais contra TEST_CITY_A,
# sem fixture transacional (o padrão do record_vaccination_spec): pop(timeout:),
# e o after solta as threads e apaga tudo o que commitou.
RSpec.describe Zoonoses::Label, "× duas coletas em threads", type: :model do
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
    @before = in_city { snapshot }
    @ids = in_city do
      neighborhood = Neighborhood.create!(name: "Bairro corrida #{SecureRandom.hex(3)}", source: "manual")
      survey = leish_survey!(blocks: [ city_block!(neighborhood: neighborhood, number: "1") ])
      { survey: survey.id, animals: [ animal!.id, animal!.id ] }
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

  def collect_now(go, index, hold: nil)
    go.pop(timeout: 5) or raise "timeout esperando go"
    in_city do
      LeishTest.transaction do
        survey = LeishSurvey.find(@ids[:survey])
        label = described_class.next!(survey: survey, year: 2026)
        LeishTest.create!(leish_survey: survey, animal_id: @ids[:animals][index], collected_on: Time.zone.today, label: label)
        if hold
          hold << true
          release.pop(timeout: 10) or raise "timeout esperando release"
        end
        label
      end
    end
  rescue StandardError => e
    e
  end

  it "seq 0001 e 0002, sem colisão" do
    holding = Queue.new
    go_first = Queue.new
    first_result = Queue.new
    threads << (holder = Thread.new { first_result << collect_now(go_first, 0, hold: holding) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << collect_now(go_second, 1) })
    go_second << true
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera na trava da etiqueta

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    first, second = first_result.pop(timeout: 1), second_result.pop(timeout: 1)
    prefix = "LV-2026-#{@ids[:survey].delete('-')[0, 6].upcase}"
    expect([ first, second ]).to eq([ "#{prefix}-0001", "#{prefix}-0002" ])
    in_city { expect(LeishTest.where(leish_survey_id: @ids[:survey]).order(:label).pluck(:label)).to eq([ first, second ]) }
  end
end

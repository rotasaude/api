require "rails_helper"
require "rake"

# triage:audit_weighted_scoring recalcula, com o motor já corrigido (8e1a9dc),
# as triagens concluídas de protocolo weighted e compara com o persistido.
# Registros de verdade no banco de TEST_CITY_A — mesmo padrão de
# city_rake_spec.rb (city:invite_admin): registra a cidade no catálogo sem
# abrir conexão nova.
RSpec.describe "triage:audit_weighted_scoring rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("triage:audit_weighted_scoring")
  end

  before do
    Rake::Task["triage:audit_weighted_scoring"].reenable
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APPLY").and_return(nil)
    allow(ENV).to receive(:[]).with("CITY_SLUG").and_return(city.slug)
  end

  let!(:city) do
    City.find_by(slug: TEST_CITY_A.slug) || City.create!(
      slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
      database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
      schema_version: CitySchema.expected_version.to_s
    )
  end

  def invoke
    original_stdout, $stdout = $stdout, StringIO.new
    original_stderr, $stderr = $stderr, StringIO.new
    Rake::Task["triage:audit_weighted_scoring"].invoke
    [ $stdout.string, $stderr.string ]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  # Pesos do protocolo padrão: tosse=true 3, febre=true 5; alta a partir de 5.
  # Respostas em string, como o canal grava ("true"/"false"): o motor trata a
  # resposta `false` booleana como ausente (`answers[id] || ...`).
  def completed_triage(definition, answers:, tier:, priority:, outcome:)
    convo = Conversation.create!(phone: "+55419#{rand(10_000_000..99_999_999)}", state: "greeting")
    Triage.create!(conversation: convo, protocol_definition: definition, protocol_name: definition.name,
                   status: "completed", completed_at: Time.current, answers: answers,
                   tier: tier, priority: priority, outcome: outcome)
  end

  # Gravadas como o bug gravava: score 0, tier mais baixo.
  let!(:records) do
    CityConnection.with(city) do
      weighted = create_default_protocol!
      broken = ProtocolDefinition.create!(
        name: "quebrado", version: 1, status: "active",
        definition: weighted.definition.merge("name" => "quebrado")
      )
      unweighted = ProtocolDefinition.create!(
        name: "sem-score", version: 1, status: "active",
        definition: weighted.definition.except("scoring").merge("name" => "sem-score")
      )

      {
        tier_changes: completed_triage(weighted, answers: { "tosse" => "true", "febre" => "true" },
                                                 tier: "baixa", priority: 9, outcome: { "score" => 0, "trail" => [] }),
        unchanged: completed_triage(weighted, answers: { "tosse" => "false" },
                                              tier: "baixa", priority: 9, outcome: { "score" => 0, "trail" => [] }),
        # answers vazio: a fonte passa a ser o trail persistido.
        from_trail: completed_triage(weighted, answers: {}, tier: "baixa", priority: 9,
                                               outcome: { "score" => 0, "trail" => [ { "step" => "tosse", "answer" => "true" },
                                                                                     { "step" => "febre", "answer" => "false" } ] }),
        errored: completed_triage(broken, answers: { "tosse" => "true" }, tier: "baixa", priority: 9, outcome: {}),
        not_weighted: completed_triage(unweighted, answers: { "tosse" => "true", "febre" => "true" },
                                                   tier: "baixa", priority: 9, outcome: { "score" => 0 })
      }
    end
  end

  before do
    allow(Protocols::Definitions).to receive(:build).and_wrap_original do |original, definition|
      raise ArgumentError, "definição corrompida" if definition["name"] == "quebrado"
      original.call(definition)
    end
  end

  def reloaded(key) = CityConnection.with(city) { records.fetch(key).reload }

  it "reports what would change in dry-run, counting changed/unchanged/errored, and writes nothing" do
    out, err = invoke

    expect(out).to include("[audit] cidade: #{city.slug}")
    expect(out).to include("[audit] modo: dry-run (somente relatório)")
    expect(out).to include("[audit] definições weighted: 2 | triagens weighted concluídas: 4")
    expect(out).to match(/triage=#{records[:tier_changes].id} \[TIER\/PRIORITY MUDA ⚠\]\n  tier:\s+"baixa"\s+-> "alta"/)
    expect(out).to match(/triage=#{records[:from_trail].id} \[só score\/trail\]/)
    expect(out).to match(/score:\s+0\s+-> 3/)
    expect(out).not_to include("triage=#{records[:unchanged].id}")
    expect(out).not_to include("triage=#{records[:not_weighted].id}")
    expect(out).to include("[audit] total=4 alterar=2 inalteradas=1 erros=1")
    expect(out).to include("[audit] dry-run: nada foi gravado. Rode com APPLY=1 para aplicar.")
    expect(out).not_to include("-> gravado.")
    expect(err).to include("triage=#{records[:errored].id} ERRO: ArgumentError: definição corrompida")

    expect(reloaded(:tier_changes)).to have_attributes(tier: "baixa", priority: 9)
    expect(reloaded(:tier_changes).outcome["score"]).to eq(0)
    expect(reloaded(:from_trail).outcome["score"]).to eq(0)
  end

  it "with APPLY=1 writes the recomputed tier, priority and outcome, and only for the changed triages" do
    allow(ENV).to receive(:[]).with("APPLY").and_return("1")
    untouched = reloaded(:unchanged).attributes

    out, = invoke

    expect(out).to include("[audit] modo: APPLY (gravando)")
    expect(out.scan("  -> gravado.").size).to eq(2)
    expect(out).not_to include("dry-run: nada foi gravado")

    fixed = reloaded(:tier_changes)
    expect(fixed).to have_attributes(tier: "alta", priority: 1)
    expect(fixed.outcome).to include("status" => "terminal", "tier" => "alta", "priority" => 1, "score" => 8)
    expect(fixed.outcome["trail"].map { |e| e.slice("step", "answer", "weight") })
      .to eq([ { "step" => "tosse", "answer" => "true", "weight" => 3 }, { "step" => "febre", "answer" => "true", "weight" => 5 } ])

    from_trail = reloaded(:from_trail)
    expect(from_trail).to have_attributes(tier: "baixa", priority: 9)
    expect(from_trail.outcome["score"]).to eq(3)

    expect(reloaded(:unchanged).attributes).to eq(untouched)
    expect(reloaded(:errored).outcome).to eq({})
    expect(reloaded(:not_weighted).outcome).to eq("score" => 0)
  end

  it "without CITY_SLUG audits every active city and skips the inactive ones" do
    allow(ENV).to receive(:[]).with("CITY_SLUG").and_return(nil)
    suspended = create(:city, status: "suspended")
    entered = []
    allow(CityConnection).to receive(:with).and_wrap_original do |original, c, &block|
      entered << c.slug
      original.call(c, &block)
    end

    out, = invoke

    expect(entered).to include(city.slug)
    expect(entered).not_to include(suspended.slug)
    expect(out).to include("[audit] cidade: #{city.slug}")
    expect(out).not_to include("[audit] cidade: #{suspended.slug}")
  end

  it "with CITY_SLUG audits only that city" do
    other = create(:city, status: "active")
    entered = []
    allow(CityConnection).to receive(:with).and_wrap_original do |original, c, &block|
      entered << c.slug
      original.call(c, &block)
    end

    out, = invoke

    expect(entered.uniq).to eq([ city.slug ])
    expect(out).not_to include(other.slug)
  end

  # Trail persistido: hashes com chaves string; qualquer outra forma vira {}.
  describe "rebuild_answers_from_trail" do
    def rebuild(outcome) = send(:rebuild_answers_from_trail, outcome)

    it "maps step to answer, stringifying the step" do
      expect(rebuild("trail" => [ { "step" => :tosse, "answer" => true }, { "step" => "febre", "answer" => false } ]))
        .to eq("tosse" => true, "febre" => false)
    end

    it "returns an empty hash when there is no usable trail" do
      expect(rebuild(nil)).to eq({})
      expect(rebuild("score" => 0)).to eq({})
      expect(rebuild("trail" => "nao-e-array")).to eq({})
    end
  end
end

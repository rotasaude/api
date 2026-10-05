require "rails_helper"

# Módulo 03, critério de fechamento (ADR 0009): o motor é puro — mesmas
# respostas + mesma versão → mesmo Outcome, sem banco, relógio, acaso ou
# ambiente. F-03.1: Protocol#step devolve o próximo passo sem efeito colateral.
RSpec.describe "Invariante: motor de protocolo puro (ADR 0009)" do
  include ActiveSupport::Testing::TimeHelpers

  def template = JSON.parse(File.read(Rails.root.join("config/city_templates/triage_respiratoria.json")))
  def build = Protocols::Definitions.build(template)

  def all_answers
    [
      {},
      { "tosse" => "false" },
      { "tosse" => "true" },
      { "tosse" => "true", "febre" => "false" },
      { "tosse" => "true", "febre" => "true" }
    ]
  end

  describe "arquitetura" do
    # O núcleo que avalia. Fora dele, de propósito: validation/ (o gate lê o
    # JSON Schema do disco), urgency.rb (limiar operacional lido do ambiente)
    # e definitions.rb (fábrica que chama o gate).
    def core
      %w[protocol.rb step.rb outcome.rb condition.rb condition_context.rb priority_rules.rb scoring.rb
         scoring/weighted.rb scoring/decision_table.rb]
    end

    def forbidden
      /\b(ActiveRecord|ApplicationRecord|CityRecord|Rails|Current|ENV|Time|Date|DateTime|
          rand|Random|SecureRandom|File|IO|Kernel|Net|DomainEvents|Protocols\.(fetch|current))\b/x
    end

    it "the evaluation core references no database, clock, randomness, IO or environment" do
      offenders = core.flat_map do |file|
        File.readlines(Rails.root.join("app/protocols", file)).each_with_index.filter_map do |line, i|
          code = line.sub(/#.*/, "")
          "#{file}:#{i + 1}: #{line.strip}" if code.match?(forbidden)
        end
      end
      expect(offenders).to be_empty
    end
  end

  describe "Protocol#step (F-03.1)" do
    let(:protocol) { build }

    it "starts at the start step" do
      expect(protocol.step({}).id).to eq(:tosse).or eq("tosse")
    end

    it "follows the branch of the given answer" do
      expect(protocol.step("tosse" => "true").id.to_s).to eq("febre")
    end

    it "returns nil when the flow is over" do
      expect(protocol.step("tosse" => "false")).to be_nil
      expect(protocol.step("tosse" => "true", "febre" => "false")).to be_nil
    end

    it "accepts symbol keys like string keys" do
      expect(protocol.step(tosse: "true").id.to_s).to eq("febre")
    end

    it "never mutates the answers it receives" do
      answers = { "tosse" => "true" }.freeze
      expect { protocol.step(answers); protocol.evaluate(answers) }.not_to raise_error
    end
  end

  describe "pureza" do
    it "same answers + same version → same Outcome, on fresh builds, at any time" do
      all_answers.each do |answers|
        first = build.evaluate(answers).to_h
        again = build.evaluate(answers).to_h
        later = travel_to(Time.utc(2031, 1, 1)) { build.evaluate(answers).to_h }
        expect([again, later]).to all(eq(first)), answers.inspect
      end
    end

    it "evaluates without touching the database" do
      protocol = build
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        all_answers.each { |answers| protocol.step(answers); protocol.evaluate(answers) }
      end
      expect(queries).to be_empty
    end

    it "hands out frozen values" do
      outcome = build.evaluate("tosse" => "true", "febre" => "true")
      expect(outcome).to be_frozen
      expect(outcome.trail).to be_frozen
      expect(outcome.explanation).to be_frozen.and all(be_frozen)
    end
  end
end

# spec/services/campaigns/audience_schema_spec.rb
require "rails_helper"

RSpec.describe Campaigns::AudienceSchema do
  let(:uuid) { SecureRandom.uuid }
  let(:from) { (Time.zone.today - 30).iso8601 }
  let(:to) { (Time.zone.today - 1).iso8601 }

  def audience(geo: { "scope" => "city" }, all: [])
    { "version" => 1, "geo" => geo, "clinical" => { "all" => all } }
  end

  def errors_of(value) = described_class.errors(value)
  def paths(value) = errors_of(value).map { |e| e[:path] }

  it "aceita os três recortes e cada um dos sete critérios" do
    valid = [
      audience,
      audience(geo: { "scope" => "unit", "health_unit_id" => uuid }),
      audience(geo: { "scope" => "neighborhoods", "neighborhood_ids" => [ uuid ] }),
      audience(all: [
        { "kind" => "protocol_period", "protocol_name" => "triage-respiratoria", "from" => from, "to" => to },
        { "kind" => "triage_tier", "tiers" => [ "alta" ], "from" => from, "to" => to },
        { "kind" => "triage_incomplete", "from" => from, "to" => to },
        { "kind" => "attendance_outcome", "outcomes" => %w[discharged left], "health_unit_id" => uuid,
          "from" => from, "to" => to },
        { "kind" => "triaged_not_attended", "from" => from, "to" => to },
        { "kind" => "appointment_no_show", "from" => from, "to" => to },
        { "kind" => "appointment_request_open", "kinds" => [ "return" ], "target_unit_id" => uuid }
      ]),
      audience(all: [ { "kind" => "appointment_request_open" } ])
    ]
    valid.each { |a| expect(errors_of(a)).to eq([]), a.inspect }
  end

  it "aceita chaves de símbolo e período de um dia só, hoje" do
    today = Time.zone.today.iso8601
    value = { version: 1, geo: { scope: "city" }, clinical: { all: [ { kind: "appointment_no_show", from: today, to: today } ] } }
    expect(errors_of(value)).to eq([])
    expect(described_class.valid?(value)).to be(true)
  end

  it "recusa o que não é objeto, versão errada, chave extra e partes faltando" do
    expect(errors_of(nil)).to eq([ { path: "/", message: "not_an_object" } ])
    expect(paths([ 1 ])).to eq([ "/" ])
    expect(errors_of(audience.merge("version" => 2))).to eq([ { path: "/version", message: "must_be_1" } ])
    expect(errors_of(audience.merge("extra" => true))).to eq([ { path: "/extra", message: "unknown_key" } ])
    expect(errors_of(audience.except("clinical"))).to eq([ { path: "/clinical", message: "required" } ])
    expect(errors_of(audience(geo: "city"))).to eq([ { path: "/geo", message: "not_an_object" } ])
  end

  it "recorte: escopo desconhecido, unidade sem UUID, bairros vazios, repetidos ou mais de 50" do
    expect(errors_of(audience(geo: { "scope" => "estado" }))).to eq([ { path: "/geo/scope", message: "invalid_scope" } ])
    expect(errors_of(audience(geo: { "scope" => "unit" }))).to eq([ { path: "/geo/health_unit_id", message: "required" } ])
    expect(errors_of(audience(geo: { "scope" => "unit", "health_unit_id" => "ubs-1" })))
      .to eq([ { path: "/geo/health_unit_id", message: "invalid_uuid" } ])
    expect(errors_of(audience(geo: { "scope" => "city", "neighborhood_ids" => [ uuid ] })))
      .to eq([ { path: "/geo/neighborhood_ids", message: "unknown_key" } ])
    {
      [] => "empty", Array.new(51) { SecureRandom.uuid } => "too_many", [ uuid, uuid ] => "duplicate", "Centro" => "not_a_list"
    }.each do |ids, message|
      expect(errors_of(audience(geo: { "scope" => "neighborhoods", "neighborhood_ids" => ids })))
        .to eq([ { path: "/geo/neighborhood_ids", message: message } ]), message
    end
    expect(errors_of(audience(geo: { "scope" => "neighborhoods", "neighborhood_ids" => [ uuid, "x" ] })))
      .to eq([ { path: "/geo/neighborhood_ids/1", message: "invalid_uuid" } ])
  end

  it "critérios: mais de 7, kind desconhecido, campo extra, campo faltando, valor fora da lista" do
    no_show = { "kind" => "appointment_no_show", "from" => from, "to" => to }
    expect(errors_of(audience(all: Array.new(8) { no_show }))).to eq([ { path: "/clinical/all", message: "too_many" } ])
    expect(errors_of(audience(all: [ { "kind" => "idade" } ]))).to eq([ { path: "/clinical/all/0/kind", message: "invalid_kind" } ])
    expect(errors_of(audience(all: [ { "from" => from } ]))).to eq([ { path: "/clinical/all/0/kind", message: "invalid_kind" } ])
    expect(errors_of(audience(all: [ no_show.merge("cpf" => "52998224725") ])))
      .to eq([ { path: "/clinical/all/0/cpf", message: "unknown_key" } ])
    expect(errors_of(audience(all: [ no_show.except("to") ]))).to eq([ { path: "/clinical/all/0/to", message: "required" } ])
    expect(errors_of(audience(all: [ { "kind" => "attendance_outcome", "outcomes" => [ "curado" ], "from" => from, "to" => to } ])))
      .to eq([ { path: "/clinical/all/0/outcomes/0", message: "invalid_value" } ])
    expect(errors_of(audience(all: [ { "kind" => "triage_tier", "tiers" => [], "from" => from, "to" => to } ])))
      .to eq([ { path: "/clinical/all/0/tiers", message: "empty" } ])
    expect(errors_of(audience(all: [ { "kind" => "protocol_period", "protocol_name" => "  ", "from" => from, "to" => to } ])))
      .to eq([ { path: "/clinical/all/0/protocol_name", message: "invalid_value" } ])
    expect(errors_of(audience(all: [ { "kind" => "appointment_request_open", "kinds" => [ "exame" ] } ])))
      .to eq([ { path: "/clinical/all/0/kinds/0", message: "invalid_value" } ])
    expect(errors_of(audience(all: [ "appointment_no_show" ]))).to eq([ { path: "/clinical/all/0", message: "not_an_object" } ])
  end

  it "período: data inválida, futura ou invertida" do
    base = { "kind" => "triage_incomplete" }
    tomorrow = (Time.zone.today + 1).iso8601
    {
      base.merge("from" => "2026-02-30", "to" => to) => { path: "/clinical/all/0/from", message: "invalid_date" },
      base.merge("from" => from, "to" => "ontem") => { path: "/clinical/all/0/to", message: "invalid_date" },
      base.merge("from" => from, "to" => 20_260_101) => { path: "/clinical/all/0/to", message: "invalid_date" },
      base.merge("from" => from, "to" => tomorrow) => { path: "/clinical/all/0/to", message: "future_date" },
      base.merge("from" => to, "to" => from) => { path: "/clinical/all/0/from", message: "inverted_period" }
    }.each do |criterion, expected|
      expect(errors_of(audience(all: [ criterion ]))).to eq([ expected ]), criterion.inspect
    end
  end
end

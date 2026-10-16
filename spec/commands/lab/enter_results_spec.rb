require "rails_helper"

# Spec §5.6: limite de digitação bloqueia, calculado preenchido pela fórmula,
# repetição não sobrescreve, item digitado quando tudo tem valor.
RSpec.describe Lab::EnterResults do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:lipids) do
    lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Perfil lipídico", analytes: LabHelpers::LIPIDS,
              material: "Soro", container: "Tubo amarelo (gel)", instrument_test_code: "LIP")
  end
  let(:glucose) { lab_exam!(provider: provider) }
  let(:staff) { lab_staff! }

  it "calcula LDL quando os três chegam; repetição acrescenta; item digitado" do
    item = received_requisition!(provider: provider, exams: [ lipids ]).items.first
    described_class.call(item: item, values: [ { "analyte_key" => "ct", "value" => "200" }, { "analyte_key" => "hdl", "value" => "50" } ], by: staff)
    expect(item.reload.status).to eq("pending")
    described_class.call(item: item, values: [ { "analyte_key" => "tg", "value" => "150" } ], by: staff)
    expect(Lab::Effective.rows(item.reload).transform_values(&:value)).to eq("ct" => "200", "hdl" => "50", "tg" => "150", "ldl" => "120")
    expect(item.status).to eq("typed")
    described_class.call(item: item, values: [ { "analyte_key" => "hdl", "value" => "60" } ], by: staff)
    expect(Lab::Effective.rows(item.reload)["ldl"].value).to eq("110")
    expect(item.results.where(analyte_key: "hdl").count).to eq(2)
    expect(described_class.call(item: item, values: [ { "analyte_key" => "ldl", "value" => "1" } ], by: staff).reason).to eq(:unknown_analyte)
  end

  it "limite de digitação, valor ruim, amostra não recebida" do
    item = received_requisition!(provider: provider, exams: [ glucose ]).items.first
    result = described_class.call(item: item, values: [ { "analyte_key" => "glicose", "value" => "1500,1" } ], by: staff)
    expect([ result.reason, result.details[:analyte_key] ]).to eq([ :out_of_entry_range, "glicose" ])
    expect(described_class.call(item: item, values: [ { "analyte_key" => "glicose", "value" => "1500" } ], by: staff)).to be_ok
    expect(described_class.call(item: item, values: [ { "analyte_key" => "glicose", "value" => "abc" } ], by: staff).reason).to eq(:invalid_value)
    expect(Lab::Effective.rows(item.reload)["glicose"].flag).to eq("critical_high")
    fresh = open_requisition!(provider: provider, exams: [ glucose ]).items.first
    expect(described_class.call(item: fresh, values: [ { "analyte_key" => "glicose", "value" => "90" } ], by: staff).reason).to eq(:sample_not_received)
  end

  it "componente repetido na mesma entrada é recusado sem gravar nada (E5)" do
    item = received_requisition!(provider: provider, exams: [ lipids ]).items.first
    values = [ { "analyte_key" => "ct", "value" => "200" }, { "analyte_key" => "ct", "value" => "210" } ]
    result = described_class.call(item: item, values: values, by: staff)
    expect([ result.reason, result.details[:analyte_key] ]).to eq([ :invalid_values, "ct" ])
    expect(item.results.count).to eq(0)
  end

  it "mesmo instante: a última inserida vale, não a de UUID maior (E5)" do
    item = received_requisition!(provider: provider, exams: [ glucose ]).items.first
    now = Time.current
    values = ->(v) { [ { "analyte_key" => "glicose", "value" => v } ] }
    5.times do |i|
      described_class.call(item: item, values: values.call((100 + i).to_s), by: staff, now: now)
      expect(Lab::Effective.rows(item.reload)["glicose"].value).to eq((100 + i).to_s)
    end
  end

  it "calculado incalculável recusa a entrada inteira, sem deixar valor velho (I1)" do
    ratio = [ { "key" => "a", "name" => "A", "unit" => nil, "value_type" => "numeric", "choices" => [], "decimals" => 0, "reference_ranges" => [],
                "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => nil },
              { "key" => "b", "name" => "B", "unit" => nil, "value_type" => "numeric", "choices" => [], "decimals" => 0, "reference_ranges" => [],
                "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => nil },
              { "key" => "r", "name" => "R", "unit" => nil, "value_type" => "numeric", "choices" => [], "decimals" => 2, "reference_ranges" => [],
                "entry_min" => nil, "entry_max" => nil, "critical_low" => nil, "critical_high" => nil, "formula" => "a / b" } ]
    exam = lab_exam!(provider: provider, sigtap_code: "0202010503", name: "Razão", analytes: ratio, instrument_test_code: "RAZ")
    item = received_requisition!(provider: provider, exams: [ exam ]).items.first
    type!(item, { a: 10, b: 4 })
    expect(Lab::Effective.rows(item.reload)["r"].value).to eq("2.50")
    result = described_class.call(item: item, values: [ { "analyte_key" => "b", "value" => "0" } ], by: staff)
    expect([ result.reason, result.details[:analyte_key] ]).to eq([ :invalid_values, "r" ])
    expect(item.reload.results.where(analyte_key: "b").count).to eq(1)
    expect(Lab::Effective.rows(item)["r"].value).to eq("2.50")
  end

  it "choose de componente calculado é recusado; choose de insumo refaz o calculado" do
    item = received_requisition!(provider: provider, exams: [ lipids ]).items.first
    type!(item, { ct: 200, hdl: 50, tg: 150 })
    type!(item, { hdl: 60 })
    ldl_old = item.results.where(analyte_key: "ldl").first
    releaser = lab_releaser!(provider)
    refused = Lab::ChooseResult.call(result: ldl_old, by: releaser)
    expect([ refused.reason, refused.details[:analyte_key] ]).to eq([ :unknown_analyte, "ldl" ])
    expect(item.results.reload.where(analyte_key: "ldl").count).to eq(2)
    hdl_old = item.results.where(analyte_key: "hdl").first
    expect(Lab::ChooseResult.call(result: hdl_old, by: releaser)).to be_ok
    expect(Lab::Effective.rows(item.reload)["ldl"].value).to eq("120")
  end

  it "número com mais de 15 algarismos significativos é recusado (sem entry_max)" do
    item = received_requisition!(provider: provider, exams: [ lipids ]).items.first
    expect(described_class.call(item: item, values: [ { "analyte_key" => "ct", "value" => "1234567890123456" } ], by: staff).reason).to eq(:invalid_value)
    expect(described_class.call(item: item, values: [ { "analyte_key" => "ct", "value" => "123456789012345" } ], by: staff)).to be_ok
  end
end

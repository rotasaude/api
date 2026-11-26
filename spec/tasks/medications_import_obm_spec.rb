# spec/tasks/medications_import_obm_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "medications:import_obm rake task", type: :model do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("medications:import_obm") }
  before do
    Rake::Task["medications:import_obm"].reenable
    import_test_catalog!
  end

  def run!(*args)
    out = StringIO.new
    original, $stdout = $stdout, out
    Rake::Task["medications:import_obm"].invoke(*args)
    out.string
  ensure
    $stdout = original
  end

  let(:sample_path) { Rails.root.join("spec/fixtures/obm/sample.csv").to_s }

  it "a rake importa o arquivo do caminho" do
    output = run!(sample_path)

    expect(output).to include("+3").and include("2 itens").and include("1 sem item")
    expect(ObmPresentation.count).to eq(3)
    expect(catalog_item(268_856).vmp_code).to eq("@brasil10000001")
  end

  it "a rake grava obm_catalog.imported com actor: system só com contagens" do
    run!(sample_path)

    expect(PlatformEvent.where(name: "obm_catalog.imported").last.payload)
      .to eq("actor" => "system", "added" => 3, "changed" => 0, "deactivated" => 0, "unmatched" => 1)
  end

  it "arquivo recusado aborta listando linha, coluna e código das 20 primeiras, sem o conteúdo" do
    rows = Array.new(25) { |i| "@brasil#{i};@vmp#{i};SEGREDO#{i};DESCRICAO" }
    path = Rails.root.join("tmp/obm_recusado_#{SecureRandom.hex(3)}.csv")
    File.write(path, ([ "AMPP;VMP;CATMAT;DESCRICAO" ] + rows).join("\n") + "\n")
    err = StringIO.new
    original, $stderr = $stderr, err
    expect { run!(path.to_s) }.to raise_error(SystemExit)
    $stderr = original

    lines = err.string.lines.grep(/\Alinha /)
    expect(lines.size).to eq(20)
    expect(lines.first).to include("linha 2").and include("catmat").and include("invalid")
    expect(err.string).not_to include("SEGREDO")
    expect(ObmPresentation.count).to eq(0)
  ensure
    $stderr = original if original
    File.delete(path) if path && File.exist?(path)
  end

  it "sem caminho ou com arquivo que não existe, aborta sem tocar o catálogo" do
    expect { run!(nil) }.to raise_error(SystemExit)
    Rake::Task["medications:import_obm"].reenable
    expect { run!("/nao/existe.csv") }.to raise_error(SystemExit)
    expect(ObmPresentation.count).to eq(0)
  end
end

require "rails_helper"

# Auto-testes da varredura de fonte (spec/support/source_scan.rb), usada pelas
# guardas de eventos e de log dos invariantes (21c, 22, 31).
RSpec.describe SourceScan do
  include described_class

  def scanned(src)
    Tempfile.create([ "scan", ".rb" ]) do |file|
      file.write(src)
      file.flush
      balanced_calls(/DomainEvents\.publish\(/, [ file.path ]).map(&:last)
    end
  end

  it "lê a chamada multilinha inteira, com parênteses aninhados" do
    calls = scanned(<<~RUBY)
      DomainEvents.publish("a.b",
                           x_id: f(1, g(2)),
                           month: m)
      DomainEvents.publish("c.d", y_id: 1)
    RUBY
    expect(calls.size).to eq(2)
    expect(top_level_args(calls.first)).to eq([ %("a.b"), "x_id: f(1, g(2))", "month: m" ])
    expect(top_level_args(calls.last)).to eq([ %("c.d"), "y_id: 1" ])
  end

  it "a varredura recusa payload não literal (variável ou splat)" do
    expect(top_level_args(%("x.y", **payload)).drop(1).map { |a| a[/\A([a-z_]+):\s/, 1] }).to eq([ nil ])
    expect(top_level_args(%("x.y", payload)).drop(1).map { |a| a[/\A([a-z_]+):\s/, 1] }).to eq([ nil ])
  end

  it "code_lines ignora as linhas de comentário" do
    Tempfile.create([ "scan", ".rb" ]) do |file|
      file.write(%(# "psychosocial.citado"\nbind "psychosocial.real"\n))
      file.flush
      expect(code_lines(file.path)).to eq(%(bind "psychosocial.real"\n))
    end
  end
end

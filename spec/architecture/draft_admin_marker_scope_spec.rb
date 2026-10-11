require "rails_helper"

# Escopo da marca de transação rota.draft_admin (card rotasaude/api#51; módulo
# 19a, ADR 0031). A marca abre no trigger a troca de autora do rascunho, o
# descarte e a troca de quem chamou o atendimento; por isso só dois comandos
# podem ligá-la, e só pelo helper Consultation.with_draft_admin. Procura o
# IDENTIFICADOR no arquivo inteiro (a chamada pode ser multilinha), ignorando
# linhas de comentário.
RSpec.describe "Escopo da marca rota.draft_admin" do
  def code_of(path)
    File.readlines(path).reject { |line| line.lstrip.start_with?("#", "--") }.join
  end

  def files_matching(globs, pattern)
    Dir[*globs.map { |glob| Rails.root.join(glob).to_s }].select { |path| code_of(path).match?(pattern) }
        .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort
  end

  it "with_draft_admin só é chamado por Discard e Reassign (e definido no modelo)" do
    callers = files_matching(%w[app/**/*.{rb,rake,erb} lib/**/*.{rb,rake}], /\bwith_draft_admin\b/)

    expect(callers).to eq(%w[app/commands/consultation_drafts/discard.rb
                             app/commands/consultation_drafts/reassign.rb
                             app/models/consultation.rb])
    # No modelo só a definição (def self.with_draft_admin), nunca uma chamada.
    expect(code_of(Rails.root.join("app/models/consultation.rb")).scan(/\bwith_draft_admin\b/).size).to eq(1)
    %w[discard reassign].each do |name|
      expect(code_of(Rails.root.join("app/commands/consultation_drafts/#{name}.rb")).scan(/Consultation\.with_draft_admin\b/).size).to eq(1)
    end
  end

  it "a string rota.draft_admin só aparece no helper e nos triggers (nem em migração, nem em config)" do
    users = files_matching(%w[app/**/*.{rb,rake,erb,sql} lib/**/*.{rb,rake,sql} config/**/*.{rb,yml,rake} db/**/*.{rb,sql}],
                           /rota\.draft_admin/)

    expect(users).to eq(%w[app/models/consultation.rb db/city_triggers.sql])
    # No helper, só os dois SET LOCAL ('on' e o 'off' que impede o vazamento).
    expect(code_of(Rails.root.join("app/models/consultation.rb")).scan(/rota\.draft_admin/).size).to eq(2)
  end
end

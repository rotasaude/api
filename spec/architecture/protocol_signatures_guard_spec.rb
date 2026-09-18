require "rails_helper"

# Spec de assinaturas §10: um caminho novo que publique ou ative protocolo sem
# passar pela verificação de assinaturas derrubaria a regra inteira sem nenhum
# teste vermelho. Esta guarda lê o código.
RSpec.describe "Protocol signatures guard" do
  # M4 (rodada de revisão final): a forma round-1 exigia um nome de método de
  # escrita (update!/update_all/...) IMEDIATAMENTE antes de `status:` — e por
  # isso não pegava update!(activated_at: ..., status: "active") (status não é
  # o primeiro kwarg). A forma daqui não amarra a um método: qualquer lugar
  # onde `status` (keyword `status:`, símbolo `:status` posicional depois de
  # update_column/update_attribute/write_attribute, atributo `.status =` ou
  # `[:status] =`) é associado ao valor published/active — string OU símbolo —
  # conta, não importa o que vem antes na linha. Método, não constante:
  # constante dentro de RSpec.describe vaza para Object.
  def status_write
    value = /"published"|"active"|:published(?!\w)|:active(?!\w)/
    /
      \bstatus:\s*(?:#{value})                                             |
      \.status\s*=\s*(?:#{value})                                          |
      \[:status\]\s*=\s*(?:#{value})                                       |
      (?:update_column|update_attribute|write_attribute)\s*\(\s*:status\s*,\s*(?:#{value})
    /x
  end

  # Contextos de LEITURA que a checagem por linha (ou pela janela abaixo)
  # reconhece com confiança e exclui: onde(status: ...), find_by(status: ...),
  # exists?(status: ...), comparação (== / !=), scope de AR e include? — nenhum
  # deles escreve. Não é exaustivo (não tenta reconhecer todo jeito de ler),
  # só os que dão para reconhecer sem ambiguidade.
  def read_only_context?(text)
    text.match?(/where\(|find_by\(|exists\?\(|==|!=|scope|include\?/)
  end

  # A literal ProtocolDefinition, não a palavra "protocol": app/commands/
  # conversation_advance.rb menciona "protocol" (DEFAULT_PROTOCOL_NAME, a
  # chave de tradução no_protocol) e tem uma linha com status: "active" — mas
  # é a CONVERSA que muda de estado ali (@conversation.update!(state: ...));
  # a linha com status: "active" é uma leitura (ProtocolDefinition.where(name:,
  # status: "active")), partida em três linhas (o "where(" mora duas linhas
  # acima) — read_only_context? olha a MESMA janela usada para "protocol" logo
  # abaixo, não só a linha do match, senão essa leitura multi-linha passaria
  # batido como escrita. Exigir a literal ProtocolDefinition, em vez de
  # "protocol\b", mantém no escopo todo arquivo que de fato manipula o
  # registro de protocolo, e só esse.
  def app_files_touching_protocols
    Dir[Rails.root.join("app/**/*.rb")].select { |path| File.read(path).include?("ProtocolDefinition") }
  end

  # Arquivo inteiro não basta: app/jobs/provision_city_job.rb toca
  # ProtocolDefinition (SeedProtocol.call se ProtocolDefinition.exists?(...)
  # ainda não rodou) e, longe dali, na mesma classe, também escreve
  # city.update!(status: "active") — a CIDADE, não o protocolo, sem nenhuma
  # palavra "protocol" por perto (checado à mão: confirmado que cai fora da
  # janela de ±3 linhas). Um filtro por "escreve status published/active em
  # algum lugar do arquivo" marcaria esse arquivo como ofensor por um motivo
  # errado; a checagem por PROXIMIDADE (não por arquivo inteiro) é o que evita
  # isso, e por isso a janela NÃO foi removida — tentei (M4 pede: remova se
  # zero falso positivo no código atual) e sem ela provision_city_job.rb vira
  # ofensor por engano. Fica.
  #
  # Comentário de uma linha só (`#` depois de rstrip) não conta como escrita:
  # o header de vários commands descreve a forma em prosa.
  def protocol_status_write?(path)
    lines = File.readlines(path)
    lines.each_with_index.any? do |line, i|
      next false if line.strip.start_with?("#")
      next false unless line.match?(status_write)

      window = lines[[i - 3, 0].max..(i + 3)].join
      next false if read_only_context?(window)

      window.match?(/protocol/i)
    end
  end

  it "writes a protocol status of published or active only in the three signed-act commands" do
    allowed = %w[publish.rb activate.rb revert_activation.rb].map { |f| Rails.root.join("app/commands/protocols", f).to_s }

    offenders = app_files_touching_protocols.reject { |path| allowed.include?(path) }
                                            .select { |path| protocol_status_write?(path) }

    expect(offenders).to be_empty
  end

  it "makes publish and activate ask Protocols::Signatures before the act" do
    # Fix round 1 (ruling P3): comentário mencionando Signatures.missing( não
    # basta — o header de publish.rb já cita isso em prosa. Só linhas de
    # código contam; linha cujo texto (sem espaço à esquerda) começa com "#"
    # é descartada antes de procurar a chamada real.
    %w[publish.rb activate.rb].each do |file|
      code = File.readlines(Rails.root.join("app/commands/protocols", file))
                 .reject { |line| line.strip.start_with?("#") }
                 .join
      expect(code).to include("Signatures.missing("), "#{file} publica/ativa sem perguntar as assinaturas"
    end
  end

  it "refuses the maintainer by kind of actor wherever approval is created" do
    # M8 (rodada de revisão final): grant_role.rb e invite_member.rb passaram
    # de denylist (actor_kind == "maintainer") para allowlist (actor_kind ==
    # "user") — mesma forma que sign.rb já usava. As três checagens hoje usam
    # o mesmo padrão.
    {
      "app/commands/protocols/sign.rb" => /actor_kind\s*==\s*"user"/,
      "app/commands/grant_role.rb" => /actor_kind\s*==\s*"user"/,
      "app/commands/invite_member.rb" => /actor_kind\s*==\s*"user"/
    }.each do |file, pattern|
      expect(File.read(Rails.root.join(file))).to match(pattern), "#{file} não checa o tipo de ator"
    end
  end
end

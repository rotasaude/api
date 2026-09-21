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
  def status_value
    /"published"|"active"|:published(?!\w)|:active(?!\w)/
  end

  def status_write
    /
      \bstatus:\s*(?:#{status_value})                                             |
      \.status\s*=\s*(?:#{status_value})                                          |
      \[:status\]\s*=\s*(?:#{status_value})                                       |
      (?:update_column|update_attribute|write_attribute)\s*\(\s*:status\s*,\s*(?:#{status_value})
    /x
  end

  # Task 2: a forma round-1 (M4 acima) excluía QUALQUER match com um token de
  # leitura (where(/find_by(/exists?(/==/!=/scope/include?) numa janela de ±3
  # linhas — e por isso deixava passar o padrão comum "ler, conferir, gravar":
  # `version = ProtocolDefinition.find_by(...)` numa linha e
  # `version.update!(status: "published")` duas linhas abaixo formam UMA
  # leitura e UMA escrita, não uma leitura protegendo a escrita — mas a janela
  # via as duas juntas e apagava a escrita da lista de ofensores. A decisão
  # agora é POR INSTRUÇÃO, nunca por proximidade: para o trecho de escrita
  # encontrado, anda-se para trás, caractere a caractere, até o `(` não
  # fechado que o envolve (mesma ideia de casar parênteses de um linter). Só é
  # leitura quando ESSE `(` — o que efetivamente envolve o `status` — abre um
  # where(/find_by(/exists?(. Escrita encadeada a um where
  # (`where(...).update_all(status: ...)`) não ganha essa proteção: o `(` que
  # envolve `status:` ali é do update_all, não do where — o where(/find_by(/
  # exists?( já fechou o próprio parêntese antes. E texto solto sem `(`
  # nenhum ao redor (`record.status = "active"`, `record[:status] = "active"`
  # fora de qualquer chamada) não tem como ser leitura: é escrita por
  # eliminação.
  def read_call?(name)
    name.match?(/\A(where|find_by|exists\?)\z/)
  end

  # Anda por CARACTERE no texto do ARQUIVO INTEIRO (não por linha nem por
  # janela): é o que sustenta o caso multi-linha que já vivia aqui antes —
  # `ProtocolDefinition.where(\n  name: ...,\n  status: "active"\n)` em
  # conversation_advance.rb tem o "where(" que abre duas linhas acima do
  # "status:" que fecha; casar parênteses por posição no texto acha esse
  # "where(" não importa quantas linhas atrás ele abriu, sem precisar de
  # janela nenhuma.
  def unclosed_paren_before(text, pos)
    depth = 0
    i = pos - 1
    while i >= 0
      case text[i]
      when ")" then depth += 1
      when "("
        return i if depth.zero?
        depth -= 1
      end
      i -= 1
    end
    nil
  end

  # Nome do método logo antes de um `(` — só word chars (e opcionalmente um
  # `!`/`?` final, de update!/exists?): `\z` ancorado bem no paren_idx garante
  # que é O MÉTODO DESSE `(`, não qualquer identificador solto mais atrás.
  def call_before(text, paren_idx)
    text[0...paren_idx].match(/([A-Za-z_][A-Za-z0-9_]*[!?]?)\s*\z/)
  end

  # `receptor.método(` logo antes de um `(` — usado só para distinguir
  # `city.update!(status: "active")` (não é protocolo) de
  # `protocol.update!(status: "active")` (é).
  def receiver_before(text, paren_idx)
    text[0...paren_idx].match(/(@?[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*[A-Za-z_][A-Za-z0-9_]*[!?]?\s*\z/)
  end

  # app/jobs/provision_city_job.rb toca ProtocolDefinition (SeedProtocol.call
  # se ProtocolDefinition.exists?(...) ainda não rodou) e, na mesma classe,
  # também escreve city.update!(status: "active") — a CIDADE, não o
  # protocolo. Task 2 tira a janela de proximidade com "protocol" (que
  # sustentava essa distinção antes) e põe no lugar uma lista EXPLÍCITA e
  # comentada de receptores que não são protocolo, em vez de adivinhar por
  # texto perto. Não exaustiva por design: só os receptores que hoje aparecem
  # num arquivo que também toca ProtocolDefinition.
  def non_protocol_receiver?(receiver)
    %w[city @city City].include?(receiver)
  end

  # Índice do `(` que introduz esta escrita. Para
  # update_column/update_attribute/write_attribute o método (e o `(` dele) já
  # fazem parte do match — não precisam de travessia para trás. Para
  # `status:`/`.status =`/`[:status] =` é o `(` não fechado mais próximo,
  # achado andando para trás a partir do começo do match
  # (unclosed_paren_before).
  def enclosing_paren_index(text, match)
    if match[0].match?(/\A(?:update_column|update_attribute|write_attribute)/)
      return match.begin(0) + match[0].index("(")
    end

    unclosed_paren_before(text, match.begin(0))
  end

  # Sem `(` nenhum envolvendo: escrita (não há como ser leitura). Com `(`:
  # leitura só se o método que o abre é where/find_by/exists?; senão, escrita
  # — a menos que o receptor da escrita seja explicitamente não-protocolo.
  def write_at?(text, match)
    paren_idx = enclosing_paren_index(text, match)
    return true if paren_idx.nil?

    method = call_before(text, paren_idx)
    return false if method && read_call?(method[1])

    receiver = receiver_before(text, paren_idx)
    return false if receiver && non_protocol_receiver?(receiver[1])

    true
  end

  # A literal ProtocolDefinition, não a palavra "protocol": app/commands/
  # conversation_advance.rb menciona "protocol" (DEFAULT_PROTOCOL_NAME, a
  # chave de tradução no_protocol) — exigir a literal, em vez de "protocol\b",
  # mantém no escopo todo arquivo que de fato manipula o registro de
  # protocolo, e só esse.
  def app_files_touching_protocols
    Dir[Rails.root.join("app/**/*.rb")].select { |path| File.read(path).include?("ProtocolDefinition") }
  end

  # Comentário de uma linha só (`#` depois de rstrip) some do texto ANTES da
  # travessia — não só não conta como escrita, como não pode atrapalhar o
  # casamento de parênteses: várias docstrings do projeto citam código com um
  # `(` sem o `)` correspondente na mesma linha (ex.: "exige
  # Signatures.missing(..." partido em duas linhas de comentário em
  # publish.rb). Trocar a linha inteira por uma linha em branco preserva as
  # posições de todo o resto do texto.
  def protocol_status_write?(path)
    lines = File.readlines(path)
    text = lines.map { |line| line.strip.start_with?("#") ? "\n" : line }.join

    matches = []
    text.scan(status_write) { matches << Regexp.last_match }

    matches.any? { |match| write_at?(text, match) }
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

# app/services/official_archive.rb
require "csv"
require "digest"

# Arquivo oficial do DATASUS (ADR 0028): ZIP ou pasta já extraída, com o mesmo
# leitor. Lê em fluxo (a base do CNES tem milhões de linhas), linha a linha,
# convertendo a codificação para UTF-8. Acha o arquivo por nome, sem
# diferenciar maiúsculas, em qualquer subpasta.
class OfficialArchive
  class NotFound < StandardError; end

  def self.open(path)
    path = Pathname(path.to_s)
    raise NotFound, "arquivo não encontrado: #{path}" unless path.exist?
    return yield(new(path, nil)) if path.directory?

    Zip::File.open(path.to_s) { |zip| return yield(new(path, zip)) }
  rescue Zip::Error
    raise NotFound, "não é um ZIP legível: #{path.basename}"
  end

  def initialize(path, zip)
    @path = path
    @zip = zip
  end

  def sha256
    return Digest::SHA256.file(@path.to_s).hexdigest if @zip

    files = Dir.glob(@path.join("**/*").to_s).select { |f| File.file?(f) }.sort
    Digest::SHA256.hexdigest(files.map { |f| "#{Pathname(f).relative_path_from(@path)}:#{Digest::SHA256.file(f).hexdigest}" }.join("\n"))
  end

  def each_line(pattern, encoding: "ISO-8859-1")
    open_entry(pattern) do |io|
      io.each_line do |raw|
        line = raw.dup.force_encoding(encoding).encode("UTF-8", invalid: :replace, undef: :replace).delete_prefix("﻿").chomp
        yield line unless line.strip.empty?
      end
    end
  end

  def each_row(pattern, encoding: "ISO-8859-1", col_sep: ";")
    headers = nil
    each_line(pattern, encoding: encoding) do |line|
      fields = CSV.parse_line(line, col_sep: col_sep) || []
      if headers.nil?
        headers = fields.map { |h| h.to_s.strip.upcase }
        next
      end
      yield headers.zip(fields.map { |v| v&.strip }).to_h
    end
  end

  private

  def open_entry(pattern, &block)
    name = entry_names.find { |n| File.basename(n).match?(pattern) }
    raise NotFound, "arquivo #{pattern.source} ausente em #{@path.basename}" unless name
    return @zip.get_entry(name).get_input_stream(&block) if @zip

    File.open(@path.join(name), "rb", &block)
  end

  def entry_names
    return @zip.entries.reject(&:directory?).map(&:name) if @zip

    Dir.glob(@path.join("**/*").to_s).select { |f| File.file?(f) }.map { |f| Pathname(f).relative_path_from(@path).to_s }
  end
end

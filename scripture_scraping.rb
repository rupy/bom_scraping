require 'logger'
require 'nokogiri'
require 'open-uri'
require 'kconv'
require 'csv'


class ScriptureScraping

	attr_reader :target_url

	def initialize()
		@log = Logger.new(STDERR)
		@log.level=Logger::DEBUG
		@log.debug('Initilizing instance')

		@target_url = "https://www.lds.org/scriptures/bofm/bofm-title?lang=eng"
		# @target_url = "https://www.lds.org/scriptures/bofm/1-ne/1?lang=eng"
	end

	def parse_verse(text)

		# # 特殊な文字を置き換える
		# nbsp_char_pattern = /[\u00A0]/
		# if text =~ nbsp_char_pattern
		# 	@log.info("nbsp chars found")
		# 	text.gsub!(nbsp_char_pattern, " ")
		# end

		# 先頭のAタグの削除
		text.sub!(/^<a[^>]+name="([^"]+)"[^>]*>[^<]+<\/a>/,"")
		verse_name = $1

		# 先頭の節番号の削除
		text.sub!(/^<span\sclass="verse">([^<]+)<\/span>/,"")
		verse_num = $1

		raise "This program does not support text mixes sup & span" if text =~ /<sup[^>]+>/ && text =~ /<span[^>]+>/

		# 脚注の処理
		footnote_markers = []
		footnote_hrefs = []
		footnote_rels = []
		footnote_words = []
		footnote_positions = []
		footnote_mark_pattern = /<sup[^>]+>([^<]+)<\/sup>/
		while match_pos = (text =~ footnote_mark_pattern)
			text.sub!(footnote_mark_pattern, "")
			footnote_marker = $1
			footnote_markers.push(footnote_marker)

			footnote_link_pattern = /<a[^>]+href="([^"]+)"\srel="([^"]+)">([^<]+)<\/a>/
			raise "Invalid footnote pattern" if text !~ footnote_link_pattern
			footnote_href = $1
			footnote_rel = $2
			footnote_word = $3
			text.sub!(footnote_link_pattern, footnote_word)

			footnote_hrefs.push(footnote_href)
			footnote_rels.push(footnote_rel)
			footnote_words.push(footnote_word)
			footnote_positions.push(match_pos)
		end

		# 文字修飾関係の処理
		span_classes = []
		span_positions = []
		span_lengths = []
		span_pattern = /<span[^>]+class="([^"]+)">([^<]+)<\/span>/
		while match_pos = (text =~ span_pattern)

			span_class = $1
			span_text = $2
			span_length = span_text.size

			text.sub!(span_pattern, span_text)
			span_classes.push(span_class)
			span_positions.push(match_pos)
			span_lengths.push(span_length)
		end

		# puts "++++++++++++++++++"

		# puts text
		# puts verse_name
		# puts verse_num
		# print footnote_markers
		# print footnote_hrefs
		# print footnote_rels
		# print footnote_words
		# puts

		raise 'Unknown tag found' if text =~ /</

		info = {
			verse_name: verse_name,
			verse_num: verse_num,
			footnote_markers: footnote_markers,
			footnote_hrefs: footnote_hrefs,
			footnote_rels: footnote_rels,
			footnote_rels: footnote_rels,
			footnote_words: footnote_words,
			footnote_positions: footnote_positions,
			span_classes: span_classes,
			span_positions: span_positions,
			span_lengths: span_lengths,
			text: text
		}
	end

	def parse_verses(node)
		verse_infos = []
		node.children.each do |verse_node|
			if node.name == "text"
				if node.inner_html == ""
					next
				else
					raise 'Unknown text node'
				end
			end

			if verse_node.name == "p"
				text = verse_node.inner_html

				info = parse_verse(text)

				verse_infos.push(info)
			end

		end
		verse_infos
	end

	def parse_content(content)

		content.children.each do |node|

			line = nil

			# textノードを飛ばす
			if node.name == "text"
				if node.inner_html == ""
					next
				else
					raise 'Unknown text node'
				end
			end

			next if node.name == "div" && node["id"] == "media"
			next if node.name == "div" && node["id"] == "audio-player"
			next if node.name == "ul" && node["class"].start_with?("prev-next")

			if node.name == "h2"
				puts "chapter_title"
				puts node.inner_html
			elsif ["subtitle", "intro"].include?(node["class"])
				puts node["class"]
				puts node.inner_html
				puts parse_verse(node.inner_html)
			elsif node["class"] == "summary"
				puts node["class"]
				puts parse_verse((node/"p").inner_html)
			elsif (node["class"] == "verses" || node["class"] == "article") && node["id"] == "0"
				verse_infos = parse_verses(node)
				puts node["class"]
				puts verse_infos
			else
				puts "node: #{node.name}"
				puts "#id: {node['id']}"
				puts "#class: {node['class']}"
				raise 'Unknown node'
			end
		end
	end

	def get_content(site)
		# HTMLデータを取ってくる
		charset = nil
		web_data = open(site) do |f|
			charset = f.charset
			f.read
		end

		#ドキュメント全体を取得
		doc = Nokogiri::HTML.parse(web_data, nil, charset)
		#聖文の部分を取得
		detail = doc/"div[@id='details']//h1"
		title_name = detail.inner_text
		puts title_name
		#聖文の部分を取得
		content = doc/"div[@id='content']//div[@id='primary']"

		parse_content(content)
		
	end
end

ss = ScriptureScraping.new()
ss.get_content(ss.target_url)
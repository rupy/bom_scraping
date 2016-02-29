require 'logger'
require 'nokogiri'
require 'open-uri'
require 'kconv'
require 'csv'
require 'fileutils'

class ScriptureScraper

	attr_reader :target_url
	MAX_RETRY = 10
	RETRY_TIME = 2

	def initialize(title_id = 0)
		@log = Logger.new(STDERR)
		@log.level=Logger::DEBUG
		@log.debug('Initilizing instance')


		@targets = ["bom", "d_c", "pog", "old", 'new']
		@url_list_dir = "scripture_url_lists"
		@target_files = @targets.map{|target| "#{@url_list_dir}/#{target}_list.txt"}

		set_target title_id

		# @target_url = "https://www.lds.org/scriptures/bofm/bofm-title?lang=eng"
		@target_url = "https://www.lds.org/scriptures/bofm/1-ne/1?lang=eng"

		@output_csv_dir = "scraping_output/"

		@title = nil
		@book = nil
		@chapter = nil

	end

	def try_and_retry
		retry_count = 0
		# 立て続けにたくさんのデータを取ってきていると、エラーを出すことがある。
		# その場合にはしばらく待って、再度実行する
		resp = nil
		begin
			resp = yield
		rescue => e
			print "retry" if retry_count == 0
			print "."
			sleep(RETRY_TIME * retry_count)
			retry_count += 1
			retry
		end
		puts "" if retry_count > 0
		resp
	end

	def set_target(title_id = 0)
		@title_id = title_id
		@target = @targets[title_id]
		@target_file = @target_files[title_id]
		@target_urls = open(@target_file).read.split
	end

	def check_and_get_child(node)
		if node.children.length == 1
			return node.child
		else
			raise "node '#{node.to_html}' has multiple children"
		end
	end

	def empty_text_node?(node)
		if node.name == "text"
			if node.inner_html == ""
				return true
			else
				raise 'Unknown text node'
			end
		end
		false
	end

	# 順に前の兄弟ノードのテキスト数をカウントしていく
	def position_count(node)
		# puts '============'
		# puts node.to_html
		pos = 0
		sib = node.previous_sibling
		until sib.nil?
			# puts sib.to_html
			raise "non-text node '#{sib.to_html}' found while counting posision" unless sib.name == 'text'
			pos += sib.content.length
			# puts sib.path
			sib = sib.previous_sibling
		end
		pos
	end

	def process_fn_ref(ref_node)
		@log.debug("footnote reference found")
		pos = position_count ref_node
		text = ref_node.inner_html
		if ref_node.children.to_a.any?{|c| c.name != 'text'}
			# raise "non-text node found in #{ref_node.to_html}"
			text = ref_node.content
		end
		unwrap ref_node
		rel = ref_node['rel']
		length = text.length

		fn_ref_info = {rel: rel, pos: pos, length: length, text: text}
	end

	def get_footnote(site)
		@log.debug("fetching footnotes")

		# HTMLデータを取ってくる
		charset = nil
		web_data = try_and_retry do
			open(site) do |f|
				charset = f.charset
				f.read
			end
		end

		#ドキュメント全体を取得
		doc = Nokogiri::HTML.parse(web_data, nil, charset)
		# 聖文の部分を取得
		footnote = doc/"div[@class='footnotes']//span[@class='div']"

		if footnote[0].child.name == 'text' && footnote[0].child.to_html =~ /^\s+$/
			footnote[0].child.remove
		end
		fn_ref_infos = []
		fn_st_infos = []
		begin
			redo_flag = false
			annotation_nodes = footnote[0].xpath("./*[(name()='span')or(name()='em')or(name()='a')]") # この書き方でないと順番がめちゃくちゃになる
			annotation_nodes.each do |annotation_node|
				redo_flag = annotation_node.children.length != 1
				redo_flag |= annotation_node.children.to_a.any?{|c| c.name != 'text'}
				if annotation_node.name == 'a' && annotation_node['class'] == 'load'
					fn_ref_info = process_fn_ref annotation_node
					fn_ref_infos.push fn_ref_info
				elsif annotation_node.name == 'span' || annotation_node.name == 'em'
					fn_st_info = process_style annotation_node
					fn_st_infos.push fn_st_info
				else
					raise 'Unknown annotation found'
				end
				if redo_flag
					@log.debug("Footnote annotation process redo: #{footnote[0].to_html}")
					break
				end
			end
		end while redo_flag

		[footnote[0].content, fn_ref_infos, fn_st_infos]
	end

	def process_footnote(sup_node)

		@log.debug("footnote found")

		marker = sup_node.inner_html
		anchor_node = sup_node.next_sibling
		if anchor_node.nil? # マラキの最後にはfootnoteのマーカーがあとに来るスタイルのものがある
			anchor_node = sup_node.previous_sibling
			raise 'invalid footnote found' if anchor_node.nil?
			pos = position_count anchor_node
		else # 通常はこちら
			pos = position_count sup_node
		end
		href = anchor_node['href']
		rel = anchor_node['rel']
		raise "invlalid footnote found '#{anchor_node.parent.to_html}'" unless anchor_node.name == 'a'
		if anchor_node.children.to_a.any?{|c| c.name != 'text'}
			@log.debug("nest footnote found")
			text = anchor_node.content
			# raise "non-text node found in #{anchor_node.to_html}"
		else
			text = anchor_node.inner_html
		end
		if sup_node.children.to_a.any?{|c| c.name != 'text'} # 教義と聖約はmarkerタグを含んでいるけれど予め削除しているので問題ない	
			raise "non-text node found in #{sup_node.to_html}"
		end

		length = text.length

		sup_node.remove
		anchor_node.swap(anchor_node.children)

		footnote, fn_ref_infos, fn_st_infos = get_footnote rel
		# footnote = 'none'

		footnote_info = {marker: marker, href: href, rel: rel, footnote: footnote, fn_ref_infos: fn_ref_infos, fn_st_infos: fn_st_infos, pos: pos, length: length, text: text}
	end

	def process_style(style_node)
		@log.debug("style found")
		style_type = 'none'
		if style_node.name == 'span'
			style_type = style_node['class']
		elsif style_node.name == 'em'
			style_type = 'em'
		else
			raise 'Something wrong: unknown style found'
		end
		pos = position_count style_node
		if style_node.children.to_a.any?{|c| c.name != 'text'}
			# 脚注がスタイルの中に含まれている場合（2ne22:2, D&C20:38）
			text = ''
			style_node.children.each do |sub_st_node|
				next if sub_st_node.name == 'sup'
				if sub_st_node.name == 'text'
					text += sub_st_node.content
				else
					text += sub_st_node.inner_html 
				end
			end
		# elsif style_type == 'label' && style_node.child.name ==  'a'
		# 	@log.debug("label found")
		# 	text = style_node.child.inner_html
		else
			text = style_node.inner_html
		end
		length = text.length

		style_node.swap(style_node.children)

		style_info = {type: style_type, pos: pos, length: length, text: text}
	end

	def process_ref(ref_node)
		@log.debug("scripture reference found")
		pos = position_count ref_node
		text = ref_node.inner_html
		if ref_node.children.to_a.any?{|c| c.name != 'text'}
			raise "non-text node found in #{ref_node.to_html}"
		end
		ref_node.swap(ref_node.children)
		href = ref_node['href']
		length = text.length

		ref_info = {href: href, pos: pos, length: length, text: text}
	end

	def unwrap(node)
		node.swap(node.children)
	end

	def parse_verse(verse_node, type='verse')

		# puts verse_node.to_html
		# 先頭のAタグの削除
		anchor_node = verse_node.at_css("a.dontHighlight")
		unless anchor_node.nil?
			anchor_node.remove
			verse_name = anchor_node['name']
		end
		if verse_name == 'closing' # 三人の証人の証で登場
			@log.info("closing paragraph found ... skip")
			return nil
		end
		if verse_node.child.name == 'p'
			@log.info("nesting paragraph found ... skip")
			return nil
		end
		if verse_node.inner_text =~ /^\s$/
			# D&C102章は署名の前にからの段落があるのでここで飛ばす
			@log.info("empty paragraph found ... skip: '#{verse_node.inner_html}'")
			return nil
		end

		# 先頭の節番号の削除
		span_node = verse_node.at_css("span.verse")
		unless span_node.nil?
			span_node.remove 
			verse_num = span_node.inner_html
			verse_num.gsub!(/\u00A0/,"")
			raise 'non-number verse num found' unless verse_num =~ /^\d+$/
		end

		# 預言者ジョセフ・スミスの証の2重span解消
		language_node = verse_node.at_css("span.langauge") # languageのタイポだと思われる
		unless language_node.nil?
			language_node.swap language_node.children
		end

		# 教義と聖約はsupの中にmarkerタグを含んでいるので削除
		marker_nodes = verse_node/"marker"
		marker_nodes.each do |marker_node|
			unwrap marker_node
		end

		footnote_infos = []
		style_infos = []
		ref_infos = []
		begin
			redo_flag = false # 初めfalseにしておかなけれannotationが一切見つからなかった時に無限ループになる
			annotation_nodes = verse_node.xpath("./*[((name()='span')or(name()='em')or(name()='sup')or((name()='a')and((@class='scriptureRef')or(@href='#note'))))]") # この書き方でないと順番がめちゃくちゃになる
			annotation_nodes.each do |annotation_node|

				# 子供が複数見つかった時にはタグが入れ子になっているのであとでやり直さなければいけない
				# 子供が一つでも子供がtextノード出ない場合は入れ子になっている（歴代史下17:4で登場）
				# xpathによるタグの取得自体からやり直す理由はswapによってannotation_nodeの中身が空っぽになってしまうため処理が施せないことによる
				redo_flag = annotation_node.children.length != 1
				redo_flag |= annotation_node.children.to_a.any?{|c| c.name != 'text'}

				if annotation_node.name == 'em' || annotation_node.name == 'span'
					# 文字修飾関係の処理
					style_info = process_style annotation_node
					style_infos.push style_info
				elsif annotation_node.name == 'sup' && annotation_node['class'] == 'studyNoteMarker'

					# footnoteの中にタグが含まれている
					anchor_node = annotation_node.next_sibling
					anchor_node = annotation_node.previous_sibling if anchor_node.nil?
					raise 'invalid footnote found' if anchor_node.nil?
					redo_flag |= anchor_node.children.length != 1
					redo_flag |= anchor_node.children.to_a.any?{|c| c.name != 'text'}
					# 脚注の処理
					footnote_info = process_footnote annotation_node
					footnote_infos.push footnote_info
				elsif annotation_node.name == 'a' && annotation_node['class'] == 'scriptureRef'
					# 聖文中で他の聖文が引用されている部分のリンクの処理
					ref_info = process_ref annotation_node
					ref_infos.push ref_info
				elsif annotation_node.name == 'a' && annotation_node['href'] == '#note' && annotation_node['class'] != 'footnote'
					# ジョセフ・スミス歴史で出てくるnoteの処理	
					ref_info = process_ref annotation_node
					ref_infos.push ref_info
				elsif annotation_node.name == 'a' && annotation_node['class'] == 'footnote'
					# マラキの終わりにある特殊な脚注
					next
				else
					raise 'Unknown annotation found'
				end

				if redo_flag
					@log.debug("Annotation process redo: #{verse_node.to_html}")
					break
				end
			end
		end while redo_flag

		text = verse_node.inner_html

		if verse_node.child.name == 'img'
			@log.debug("img tag found")
			img_node = check_and_get_child(verse_node)
			src = img_node['src']
			alt = img_node['alt']
			img_info = "{src=#{src},alt=#{alt}}"
			text = img_info
		end

		# 特殊な文字を置き換える
		# nbsp_char_pattern = /[\u00A0]/
		# if text =~ nbsp_char_pattern
		# 	@log.info("nbsp chars found")
		# 	text.gsub!(nbsp_char_pattern, " ")
		# end

		# puts "++++++++++++++++++"

		# puts text
		# puts verse_name
		# puts verse_num
		# print footnote_markers, footnote_hrefs, footnote_rels, footnote_words
		# puts

		raise "Unknown tag '#{$1}' found in '#{text}'" if text =~ /(<[^>]+>)/

		info = {
			verse_name: verse_name,
			verse_num: verse_num,
			type: type,
			footnote_infos: footnote_infos,
			style_infos: style_infos,
			ref_infos: ref_infos,
			text: text
		}
	end

	def build_info(
		verse_name: nil,
		verse_num: nil,
		type: nil,
		footnote_infos: nil,
		style_infos: nil,
		ref_infos: nil,
		text: nil)
		
		info = {
			verse_name: verse_name,
			verse_num: verse_num,
			type: type,
			footnote_infos: footnote_infos,
			style_infos: style_infos,
			ref_infos: ref_infos,
			text: text
		}
	end

	def parse_verses(node, type='verses')
		verse_infos = []
		node.children.each do |verse_node|
			next if empty_text_node? verse_node

			if verse_node.name == "p"
				if type == 'verses'
					@log.debug('verse')
					info = parse_verse(verse_node) # p要素
				else
					@log.debug(type)
					info = parse_verse(verse_node, type) # p要素
				end
				verse_infos.push(info) unless info.nil?
			elsif verse_node.name == "div" && verse_node['class'] == 'closing'
				@log.debug("closing")
				info = parse_verse(verse_node, 'closing') # div要素
				verse_infos.push(info) unless info.nil?
			elsif verse_node.name == "div" && (verse_node['class'] == 'signature' || verse_node['class'] == 'office')
				@log.debug(verse_node['class'])
				eid = verse_node['eid'] # これは何？
				words = verse_node['words'] # これは何？
				info = parse_verse(verse_node, 'signature') # div要素
				verse_infos.push(info) unless info.nil?
			elsif verse_node.name == "div" && verse_node['class'] == 'figure'
				if check_and_get_child(verse_node).name == 'ol' && check_and_get_child(verse_node)['class'] == 'number' # モルモン書の概要で登場, アブラハム書の模写にも
					check_and_get_child(verse_node).children.each do |li_node|
						next if empty_text_node? li_node
						eid = li_node['eid'] # これは何？
						words = li_node['words'] # これは何？
						@log.debug("figure_number")
						info = parse_verse(li_node, 'figure_number')
						verse_infos.push(info) unless info.nil?
					end
				elsif check_and_get_child(verse_node).name == 'ul' && check_and_get_child(verse_node)['class'] == 'noMarker' # D&Cの前書きで登場
					@log.debug("figure_nomarker")
					check_and_get_child(verse_node).children.each do |li_node|
						next if empty_text_node? li_node
						if li_node.name == 'div' && li_node['class'] == 'preamble'
							@log.debug("preamble")
							info = parse_verse(li_node, 'preamble')
						elsif li_node.name == 'li'
							p_node = (li_node/"p[1]")[0] # pノードの前後に空のテキストノードが入っている
							raise "Unknown node '#{p_node.to_html}' found" unless p_node.name == 'p'
							@log.debug("figure_nomerker")
							info = parse_verse(p_node, 'figure_nomerker')
						else
							raise "Unknown node '#{li_node.to_html}' found"
						end
						verse_infos.push(info) unless info.nil?
					end
				end
			elsif verse_node.name == "div" && verse_node['class'] == 'topic' # D&Cの前書きで登場
				verse_node.children.each do |topic_node|
					next if empty_text_node? topic_node
					if topic_node.name == 'h2'
						@log.debug("topic_header")
						info = parse_verse(topic_node, 'topic_header')
					elsif topic_node.name == 'p'
						@log.debug("topic")
						info = parse_verse(topic_node, 'topic')
					elsif topic_node['class'] == 'summary' # ジョセフ・スミス歴史で登場
						@log.debug("topic_summary")
						if check_and_get_child(topic_node).name == 'p'
							info = parse_verse(check_and_get_child(topic_node), 'topic_summary')
						else
							raise "Unknown node '#{check_and_get_child(topic_node).name}' found"
						end
					elsif topic_node['class'] == 'wideEllipse' # ジョセフ・スミス歴史で登場	
						@log.debug("wideEllipse")
						info = parse_verse(topic_node, 'topic')
					else
						raise "Unknown node '#{topic_node.to_html}' found"
					end
					verse_infos.push(info) unless info.nil?
				end
			elsif verse_node.name == "div" && verse_node['class'] == 'openingBlock' # 公式の宣言で登場	
				verse_node.children.each do |div_node|
					if div_node.name == 'text'
						next
					elsif div_node.name == 'div' && div_node['class'] == 'salutation'
						@log.debug("salutation")
						info = parse_verse(div_node, 'salutation')
						verse_infos.push(info) unless info.nil?
					elsif div_node.name == 'div' && div_node['class'] == 'date'
						@log.debug("date")
						info = parse_verse(div_node, 'date')
						verse_infos.push(info) unless info.nil?
					elsif div_node.name == 'div' && div_node['class'] == 'addressee'
						@log.debug("addressee")
						info = parse_verse(div_node, 'addressee')
						verse_infos.push(info) unless info.nil?
					elsif div_node.name == 'p' && div_node['class'] == ''
						@log.debug("opening_verse")
						info = parse_verse(div_node, "opening_verse")
						verse_infos.push(info) unless info.nil?
					else
						puts div_node.name
						puts div_node['class']
						raise "Unknown node '#{div_node.to_html}' found"
					end
				end
			elsif verse_node.name == "div" && verse_node['class'] == 'date' # 公式の宣言で登場	
				@log.debug("date")
				info = parse_verse(verse_node, 'date')
				verse_infos.push(info) unless info.nil?
			elsif verse_node.name == "ol" && verse_node['class'] == 'symbol' # ジョセフ・スミス歴史で登場
				li_node = check_and_get_child(verse_node)
				div_node = check_and_get_child(li_node)
				div_node.children.each do |symbol_node|
					if symbol_node.name == 'span' && symbol_node['class'] == 'label'
						@log.debug("label found ... skip")
						next
					else
						@log.debug("symbol")
						info = parse_verse(symbol_node, 'symbol')
						verse_infos.push(info) unless info.nil?
					end
				end
			elsif verse_node.name == "div" && verse_node['class'] == 'blockQuote' # 欽定訳のタイトルページで登場	
				@log.debug("blockQuote")
				info = parse_verse(verse_node, 'blockQuote')
				verse_infos.push(info) unless info.nil?
			else
				raise "Unknown node '#{verse_node.to_html}' found"
			end

		end
		verse_infos
	end

	def parse_chr_table(table_node)

		all_chr_ref_infos = []
		output = ''
		row_concat_count_arr = [0, 0, 0, 0]
		table_node.children.each_with_index do |tr_node|

			chr_ref_infos = []
			next if empty_text_node? tr_node

			col_idx = 0
			output += '|'
			tr_node.children.each_with_index do |td_node|
				next if empty_text_node? td_node

				if row_concat_count_arr[col_idx] > 0
					row_concat_count_arr[col_idx] -= 1
					output += 'v|'
					col_idx += 1
				end

				cell_type = td_node.name
				col_span = td_node['colspan'].to_i
				row_span = td_node['rowspan'].to_i

				if row_span.to_i > 0
					raise 'row concatination error ocurred' if row_concat_count_arr[col_idx] > 0
					row_concat_count_arr[col_idx] = row_span - 1
				end


				td_node.children.each do |p_node|
					next if empty_text_node? p_node
					# 先頭のAタグの削除
					anchor_node = p_node.at_css("a.dontHighlight")
					unless anchor_node.nil?
						anchor_node.remove
					end
					p_node.children.each do |cell_node|
						next if empty_text_node? p_node
						output += cell_node.content
						if col_idx == 3 && cell_node.name == 'a' && cell_node['class'] == 'scriptureRef'
							# 聖文中で他の聖文が引用されている部分のリンクの処理
							ref_info = process_ref cell_node
							chr_ref_infos.push ref_info
						elsif col_idx == 3 && cell_node.name == 'a' && cell_node['href'] == '#note'
							# 聖文中で他の聖文が引用されている部分のリンクの処理
							ref_info = process_ref cell_node
							chr_ref_infos.push ref_info
						end
					# puts td_node.to_html
					end
				end
				(col_span-1).times do
					output += '|>'
				end
				output += '|'
				col_idx += col_span
				all_chr_ref_infos.push chr_ref_infos
			end
			output += "\n"
		end
		# print all_chr_ref_infos
		build_info text: output
	end

	def parse_chr(chr_node)
		infos = []
		if chr_node.name == 'div' && chr_node["class"] == "article"
			chr_node.children.each do |div_node|
				next if empty_text_node? div_node
				if div_node.name == 'div' && div_node["class"] == "figure"
					div_node.children.each do |child_node|
						next if empty_text_node? child_node
						if child_node.name == 'table' && child_node["class"] == "lds-table"
							info = parse_chr_table child_node
							infos.push info
						elsif child_node.name == 'b'
							next
						elsif child_node.name == 'div'
							span_node = child_node.at_xpath("span")
							# aタグは削除する
							a_node = span_node.child
							unwrap a_node
							# 再度spanを取得し段落の中に入れる
							span_node = child_node.at_xpath("span")
							p_node = child_node.at_xpath("p")
							p_node.child.after span_node

							info = parse_verse child_node.child
							infos.push info
						else
							raise "Unknown node '#{child_node.to_html}' found"
						end
					end
				else
					raise "Unknown node '#{div_node.to_html}' found"
				end
			end
		else
			raise "Unknown node '#{chr_node.to_html}' found"
		end
		infos
	end

	def parse_content(content)

		all_infos = []
		content.children.each do |node|

			line = nil

			# textノードを飛ばす
			next if empty_text_node? node

			next if node.name == "div" && node["id"] == "media"
			next if node.name == "div" && node["id"] == "audio-player"
			next if node.name == "ul" && node["class"].start_with?("prev-next")

			if @book == 'chron-order'
				infos = parse_chr node
				all_infos.push *infos
			elsif node.name == "h2"
				@log.info("chapter_title")
				# puts node.inner_html
				info = build_info(type: "chapter_title", text: node.inner_html)
				all_infos.push info

			elsif ["subtitle", "intro", "studyIntro", "closing"].include?(node["class"])
				# stydyIntroはモーサヤ9章で初登場
				@log.info(node["class"])
				info = parse_verse(node, node["class"])
				all_infos.push info
			elsif node["class"] == "summary"
				@log.info(node["class"])
				# puts node.to_html
				summary_node = check_and_get_child(node) # divの子供はp要素を持っている
				info = parse_verse(summary_node, node["class"])
				all_infos.push info
			elsif (node["class"] == "verses" || node["class"] == "article") && node["id"] == "0"
				@log.info("- #{node["class"]}")
				infos = parse_verses(node, node["class"]) # div要素
				all_infos.push *infos
			elsif node["class"] == "verses maps"
				@log.info("- #{node["class"]}")
				infos = parse_verses(node, 'maps') # div要素
				all_infos.push *infos
			else
				@log.info("node: #{node.name}")
				@log.info("id: #{node['id']}")
				@log.info("class: #{node['class']}")
				raise 'Unknown node'
			end
		end
		all_infos
	end

	def get_content(site)
		# HTMLデータを取ってくる
		charset = nil
		web_data = try_and_retry do
			open(site) do |f|
				charset = f.charset
				f.read
			end
		end

		#ドキュメント全体を取得
		doc = Nokogiri::HTML.parse(web_data, nil, charset)
		# タイトルの部分を取得
		detail = doc/"div[@id='details']//h1"
		title_name = detail.inner_text
		@log.info("@@ #{title_name} @@")
		# 聖文の部分を取得
		content = doc/"div[@id='content']//div[@id='primary']"

		all_infos = parse_content(content)
		all_infos
	end

	def write_infos_to_csv(all_infos)
		output_csv_file = "#{@output_csv_dir}/#{@target}.csv"
		footnote_csv_file = "#{@output_csv_dir}/#{@target}_fn.csv"
		style_csv_file = "#{@output_csv_dir}/#{@target}_st.csv"
		ref_csv_file = "#{@output_csv_dir}/#{@target}_rf.csv"
		fn_ref_csv_file = "#{@output_csv_dir}/#{@target}_fn_rf.csv"
		fn_st_csv_file = "#{@output_csv_dir}/#{@target}_fn_st.csv"
		@log.info("writing csv files")

		CSV.open(output_csv_file, 'w') do |writer|
			id = 0
			all_infos.each_with_index do |infos, book_id|
				infos[:infos].each_with_index do |info, chapter_id|
					writer << [id, book_id, chapter_id, infos[:title], infos[:book], infos[:chapter], info[:verse_name], info[:verse_num], info[:type], info[:text]]
					id += 1
				end
			end
		end
		CSV.open(footnote_csv_file, 'w') do |writer|
		CSV.open(fn_ref_csv_file, 'w') do |writer_fn_ref|
		CSV.open(fn_st_csv_file, 'w') do |writer_fn_st|
			id = 0
			fn_id = 0
			fn_rf_id = 0
			fn_st_id = 0
			all_infos.each_with_index do |infos, book_id|
				infos[:infos].each_with_index do |info, chapter_id|
					fn_infos = info[:footnote_infos]
					unless fn_infos.nil? || fn_infos.empty?
						fn_infos.each_with_index do |fn_info, verse_id|
							writer << [fn_id, id, book_id, chapter_id, verse_id, infos[:title], infos[:book], infos[:chapter], fn_info[:marker], fn_info[:href], fn_info[:rel], fn_info[:footnote], fn_info[:pos], fn_info[:length], fn_info[:text]]
							fn_info[:fn_ref_infos].each do |fn_ref_info|
								writer_fn_ref << [fn_rf_id, fn_id, id, book_id, chapter_id, verse_id, infos[:title], infos[:book], infos[:chapter], fn_info[:marker], fn_info[:footnote], fn_info[:text], fn_ref_info[:rel], fn_ref_info[:pos], fn_ref_info[:length], fn_ref_info[:text]]
								fn_rf_id += 1
							end
							fn_info[:fn_st_infos].each do |fn_st_info|
								writer_fn_st << [fn_st_id, fn_id, id, book_id, chapter_id, verse_id, infos[:title], infos[:book], infos[:chapter], fn_info[:marker], fn_info[:footnote], fn_info[:text], fn_st_info[:type], fn_st_info[:pos], fn_st_info[:length], fn_st_info[:text]]
								fn_st_id += 1
							end
							fn_id += 1
						end
					end
					id += 1
				end
			end
		end
		end
		end
		CSV.open(style_csv_file, 'w') do |writer|
			id = 0
			st_id = 0
			all_infos.each_with_index do |infos, book_id|
				infos[:infos].each_with_index do |info, chapter_id|
					st_infos = info[:style_infos]
					unless st_infos.nil? || st_infos.empty?
						st_infos.each do |st_info|
							writer << [st_id, id, book_id, chapter_id, infos[:title], infos[:book], infos[:chapter], st_info[:type], st_info[:pos], st_info[:length], st_info[:text]]
							st_id += 1
						end
					end
					id += 1
				end
			end
		end
		CSV.open(ref_csv_file, 'w') do |writer|
			id = 0
			rf_id = 0
			all_infos.each_with_index do |infos, book_id|
				infos[:infos].each_with_index do |info, chapter_id|
					rf_infos = info[:ref_infos]
					unless rf_infos.nil? || rf_infos.empty?
						rf_infos.each do |rf_info|
							writer << [rf_id, id, book_id, chapter_id, rf_info[:href], rf_info[:pos], rf_info[:length], rf_info[:text]]
							rf_id += 1
						end
					end
				end
				id += 1
			end
		end
	end

	def scrape_scriptures

		@log.info("start scraping: #{@target}")

		all_infos_in_book = []

		@target_urls.each do |url|
			@log.info("<#{url}>")
			@title, @book, @chapter = url.split(/\/|\?/)[4..6]
			@log.info("*** #{@title} #{@book}:#{@chapter} ***")
			infos = get_content(url)
			@chapter = '0' if @chapter.start_with? 'lang'
			all_infos_in_book.push({title: @title, book: @book, chapter: @chapter, infos: infos})
		end
		write_infos_to_csv(all_infos_in_book)
	end

end

5.times do |i|
	ss = ScriptureScraper.new(i)
	ss.scrape_scriptures
	# ss.get_content(ss.target_url)
end
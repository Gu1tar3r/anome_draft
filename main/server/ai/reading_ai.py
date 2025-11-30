import os
import json
import requests
import time
import numpy as np
from typing import List, Dict, Any, Optional
from dataclasses import dataclass
import re
from collections import Counter

@dataclass
class Chunk:
    id: str
    start: int
    end: int
    text: str
    title: Optional[str] = None

class ECNUClient:
    def __init__(self, api_key: str = None, base_url: str = "https://chat.ecnu.edu.cn/open/api/v1"):
        self.api_key = api_key or os.getenv("ECNU_API_KEY", "")
        self.base_url = base_url
        self.headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"} if self.api_key else {}

    def generate(self, prompt: str, model: str = "educhat-r1", max_tokens: int = 500,
                 temperature: float = 0.7, top_p: float = 0.8, top_k: int = 20, retries: int = 3) -> str:
        if not self.api_key:
            return "ECNU API密钥未配置，返回模拟响应。请设置ECNU_API_KEY环境变量。"
        
        url = f"{self.base_url}/chat/completions"
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "top_p": top_p,
            "top_k": top_k
        }
        
        for i in range(retries):
            try:
                response = requests.post(url, headers=self.headers, json=payload, timeout=30)
                if response.status_code == 429:
                    time.sleep(2 ** i)  # 指数退避
                    continue
                response.raise_for_status()
                result = response.json()
                return result["choices"][0]["message"]["content"]
            except Exception as e:
                if i == retries - 1:
                    return f"API调用失败: {str(e)}"
        return ""

    def get_embedding(self, text: str, model: str = "ecnu-embedding-small") -> List[float]:
        """简化版嵌入生成（实际项目应使用真实API）"""
        # 模拟嵌入向量（768维）
        return [hash(text + str(i)) % 100 / 100.0 for i in range(768)]

    def generate_tts(self, text: str, model: str = "ecnu-tts") -> bytes:
        """模拟TTS生成"""
        # 实际项目应调用真实TTS API
        return f"模拟音频数据: {text[:100]}".encode()

    def generate_image(self, prompt: str, model: str = "ecnu-image", n: int = 1) -> List[str]:
        """模拟图像生成"""
        return [f"模拟图片URL: {prompt[:50]}"]

class ReadingAI:
    def __init__(self, storage):
        self.storage = storage
        self.llm = ECNUClient()
        self.embedding_index = {}

    def ingest_book(self, book_id: str, file_type: str) -> Dict[str, Any]:
        """处理书籍，生成切片和索引"""
        try:
            book_text = self._download_book_text(book_id, file_type)
            if not book_text:
                return {"status": "error", "message": "无法下载或解析书籍文本"}
            
            chunks = self._slice_text_into_chunks(book_text)
            chunks_file_key = f"books/{book_id}/chunks.jsonl"
            self._save_chunks(chunks, chunks_file_key)
            
            # 生成简单摘要（取前500字符）
            summary = book_text[:500] + "..." if len(book_text) > 500 else book_text
            self.storage.upload_text(f"books/{book_id}/summary.txt", summary)
            
            # 构建简单的关键词索引
            self._build_keyword_index(book_id, chunks)
            
            return {"status": "success", "chunk_count": len(chunks)}
        except Exception as e:
            return {"status": "error", "message": str(e)}

    def query_with_context(self, book_id: str, question: str, position: int, 
                           selected_text: str = "", include_after: bool = False, 
                           companion_mode: bool = True) -> Dict[str, Any]:
        """根据上下文回答问题"""
        try:
            chunks = self._load_chunks(book_id)
            if not chunks:
                return {"answer": "未找到书籍分块数据", "citations": []}
            
            candidate_chunks = self._select_candidate_chunks(chunks, position, companion_mode)
            if not include_after:
                candidate_chunks = [c for c in candidate_chunks if c.end <= position]
            
            selected_chunks = self._select_relevant_chunks(book_id, candidate_chunks, question)
            context = self._build_context_text(selected_chunks)
            
            prompt = self._build_question_prompt(selected_text, context, question)
            answer = self.llm.generate(prompt, model=os.getenv("ECNU_MODEL_PRO", "educhat-r1"))
            
            citations = [
                {
                    "chunkId": c.id, 
                    "text": c.text[:200] + "..." if len(c.text) > 200 else c.text, 
                    "range": [c.start, c.end]
                } for c in selected_chunks
            ]
            
            return {
                "answer": answer, 
                "citations": citations, 
                "model": os.getenv("ECNU_MODEL_PRO", "educhat-r1"), 
                "usedCompanionMode": companion_mode
            }
        except Exception as e:
            return {"answer": f"查询失败: {str(e)}", "citations": []}

    def _build_question_prompt(self, selected_text: str, context: str, question: str) -> str:
        """构建问答提示词"""
        base_prompt = """你是一本中文书籍的AI阅读助手。请严格基于提供的文本内容回答问题，避免臆造信息。如果信息不足请明确说明。"""
        
        if selected_text:
            base_prompt += f"\n\n选中的文本：{selected_text}"
        
        base_prompt += f"\n\n上下文内容：\n{context}"
        base_prompt += f"\n\n问题：{question}"
        base_prompt += "\n\n请基于上述内容回答："
        
        return base_prompt

    def _build_keyword_index(self, book_id: str, chunks: List[Chunk]):
        """构建简单的关键词索引（替代向量索引）"""
        keyword_index = {}
        for chunk in chunks:
            words = re.findall(r'[\w\u4e00-\u9fff]+', chunk.text.lower())
            for word in set(words):
                if len(word) > 1:  # 过滤单字
                    if word not in keyword_index:
                        keyword_index[word] = []
                    keyword_index[word].append(chunk.id)
        self.embedding_index[book_id] = keyword_index

    def _select_relevant_chunks(self, book_id: str, candidate_chunks: List[Chunk], 
                               question: str, max_chunks: int = 4) -> List[Chunk]:
        """基于关键词匹配选择相关分块"""
        if book_id not in self.embedding_index:
            return candidate_chunks[:max_chunks]
        
        # 简单的关键词匹配评分
        question_words = set(re.findall(r'[\w\u4e00-\u9fff]+', question.lower()))
        scored_chunks = []
        
        for chunk in candidate_chunks:
            chunk_words = set(re.findall(r'[\w\u4e00-\u9fff]+', chunk.text.lower()))
            score = len(question_words.intersection(chunk_words))
            if score > 0:
                scored_chunks.append((score, chunk))
        
        # 按评分排序并返回前max_chunks个
        scored_chunks.sort(key=lambda x: x[0], reverse=True)
        result_chunks = [chunk for score, chunk in scored_chunks[:max_chunks]]
        
        # 如果匹配结果不足，补充位置相近的块
        if len(result_chunks) < max_chunks and candidate_chunks:
            remaining_slots = max_chunks - len(result_chunks)
            used_ids = {chunk.id for chunk in result_chunks}
            for chunk in candidate_chunks:
                if chunk.id not in used_ids and len(result_chunks) < max_chunks:
                    result_chunks.append(chunk)
        
        return result_chunks

    def generate_chapter_media(self, book_id: str, chapter_text: str, chapter_id: str) -> Dict[str, str]:
        """生成章节媒体文件（音频和视频）"""
        try:
            # 生成音频
            audio_bytes = self.llm.generate_tts(chapter_text[:1000])
            audio_key = f"books/{book_id}/audio/{chapter_id}.mp3"
            self.storage.upload_bytes(audio_key, audio_bytes)
            audio_url = self.storage.get_presign_url(audio_key)
            
            # 视频生成（待实现）
            video_url = "视频生成功能待实现"
            
            return {
                "audio_url": audio_url, 
                "video_url": video_url,
                "status": "success"
            }
        except Exception as e:
            return {
                "audio_url": "", 
                "video_url": "", 
                "status": "error",
                "message": str(e)
            }

    def character_dialogue(self, book_id: str, character: str, user_input: str, position: int) -> str:
        """与书中人物对话，仅基于已读内容"""
        try:
            chunks = self._load_chunks(book_id)
            read_chunks = [c for c in chunks if c.end <= position]
            character_context = self._extract_character_context(read_chunks, character)
            
            prompt = f"""你是《{book_id}》中的{character}。

当前情节背景：
{character_context}

读者问：{user_input}

请以{character}的身份、性格和语气回答，保持角色一致性："""
            
            return self.llm.generate(prompt, model=os.getenv("ECNU_MODEL_PRO", "educhat-r1"))
        except Exception as e:
            return f"人物对话失败: {str(e)}"

    def analyze_stay_time(self, book_id: str, stay_records: Dict[int, float]) -> Dict[str, Any]:
        """分析用户在书中停留时间最长的部分"""
        if not stay_records:
            return {"message": "无停留记录"}
        
        # 找到停留时间最长的位置
        longest_pos, duration = max(stay_records.items(), key=lambda x: x[1])
        content = self._get_text_around_position(book_id, longest_pos)
        
        # 生成简要分析
        if content:
            analysis_prompt = f"""用户在第{longest_pos}位置停留了{duration}秒，阅读了以下内容：
{content}

请简要分析用户可能对这部分内容感兴趣的原因："""
            analysis = self.llm.generate(analysis_prompt)
        else:
            analysis = "无法获取该位置的文本内容"
        
        return {
            "position": longest_pos, 
            "duration": duration, 
            "content_preview": content[:200] + "..." if len(content) > 200 else content,
            "analysis": analysis
        }

    def external_dialogue(self, imported_content: str, user_input: str) -> str:
        """基于导入内容的外部对话"""
        prompt = f"""基于以下内容回答问题：

{imported_content}

问题：{user_input}

请提供准确、相关的回答："""
        
        return self.llm.generate(prompt)

    def analyze_interest(self, book_id: str, stay_records: Dict[int, float]) -> List[str]:
        """根据停留记录分析用户兴趣并给出推荐"""
        if not stay_records:
            return ["暂无足够的停留记录来分析兴趣"]
        
        # 筛选有效停留记录（超过30秒）
        interested_positions = [pos for pos, dur in stay_records.items() if dur > 30]
        if len(interested_positions) < 2:
            return ["停留记录较少，请继续阅读以获得更准确的分析"]
        
        # 获取感兴趣的内容片段
        interested_contents = []
        for pos in interested_positions[:5]:  # 最多分析5个位置
            content = self._get_text_around_position(book_id, pos)
            if content:
                interested_contents.append(content[:300])  # 限制长度
        
        if not interested_contents:
            return ["无法获取停留位置的文本内容"]
        
        # 分析兴趣主题
        topics_prompt = f"""根据用户在这些文本片段上的长时间停留，分析用户可能感兴趣的主题：

{"；".join(interested_contents)}

请列出3-5个主要兴趣主题："""
        topics = self.llm.generate(topics_prompt)
        
        # 生成推荐
        rec_prompt = f"""基于这些兴趣主题：{topics}

请给出3-5个相关的书籍或内容推荐："""
        recommendations = self.llm.generate(rec_prompt)
        
        # 格式化推荐结果
        return [rec.strip() for rec in recommendations.split("\n") if rec.strip() and len(rec.strip()) > 5]

    # ========== 辅助方法 ==========

    def _download_book_text(self, book_id: str, file_type: str) -> str:
        """下载书籍文本内容"""
        book_key = f"books/{book_id}.{file_type}"
        return self.storage.download_text(book_key)

    def _slice_text_into_chunks(self, text: str, chunk_size: int = 2000, overlap: int = 200) -> List[Chunk]:
        """将文本切片为块"""
        chunks = []
        start = 0
        chunk_id = 0
        
        while start < len(text):
            end = min(start + chunk_size, len(text))
            
            # 尝试在句子边界分割
            if end < len(text):
                for boundary in ['。', '！', '？', '\n\n', '\n']:
                    boundary_pos = text.rfind(boundary, start, end)
                    if boundary_pos > start + chunk_size // 2:  # 确保不会切得太短
                        end = boundary_pos + len(boundary)
                        break
            
            chunk_text = text[start:end].strip()
            if chunk_text and len(chunk_text) > 50:  # 过滤过短的块
                chunks.append(Chunk(
                    id=f"chunk_{chunk_id:06d}",
                    start=start,
                    end=end,
                    text=chunk_text
                ))
                chunk_id += 1
            
            start = end - overlap if end - overlap > start else end
        
        return chunks

    def _save_chunks(self, chunks: List[Chunk], chunks_file_key: str):
        """保存分块数据"""
        chunks_data = [
            {
                "id": chunk.id, 
                "start": chunk.start, 
                "end": chunk.end, 
                "text": chunk.text
            } for chunk in chunks
        ]
        chunks_lines = [json.dumps(chunk_data, ensure_ascii=False) for chunk_data in chunks_data]
        self.storage.upload_text(chunks_file_key, "\n".join(chunks_lines))

    def _load_chunks(self, book_id: str) -> List[Chunk]:
        """加载分块数据"""
        chunks_file_key = f"books/{book_id}/chunks.jsonl"
        try:
            chunks_content = self.storage.download_text(chunks_file_key)
            chunks = []
            for line in chunks_content.splitlines():
                if line.strip():
                    chunk_data = json.loads(line)
                    chunks.append(Chunk(**chunk_data))
            return chunks
        except Exception as e:
            print(f"加载分块失败: {e}")
            return []

    def _select_candidate_chunks(self, chunks: List[Chunk], position: int, companion_mode: bool) -> List[Chunk]:
        """选择候选分块（伴读模式下只选择已读内容）"""
        if not companion_mode:
            return chunks
        return [chunk for chunk in chunks if chunk.end <= position]

    def _build_context_text(self, selected_chunks: List[Chunk]) -> str:
        """构建上下文文本"""
        context_parts = []
        for i, chunk in enumerate(selected_chunks):
            context_parts.append(f"[片段{i+1}] {chunk.text}")
        return "\n\n".join(context_parts)

    def _extract_character_context(self, chunks: List[Chunk], character: str) -> str:
        """提取角色相关上下文"""
        character_chunks = []
        for chunk in chunks:
            if character in chunk.text:
                character_chunks.append(chunk.text)
        
        # 限制上下文长度
        total_length = 0
        result = []
        for text in character_chunks:
            if total_length + len(text) > 1500:  # 限制总长度
                break
            result.append(text)
            total_length += len(text)
        
        return "\n".join(result)

    def _get_text_around_position(self, book_id: str, position: int) -> str:
        """获取指定位置附近的文本"""
        chunks = self._load_chunks(book_id)
        for chunk in chunks:
            if chunk.start <= position <= chunk.end:
                return chunk.text
        
        # 如果没找到精确匹配，返回最近的块
        if chunks:
            closest_chunk = min(chunks, key=lambda c: abs(c.start - position))
            return closest_chunk.text
        
        return ""

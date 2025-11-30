from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from typing import Dict, Any, Optional, List

router = APIRouter()

def get_ai_engine(request: Request):
    """从应用状态中获取ReadingAI实例"""
    if not hasattr(request.app.state, "ai_engine"):
        raise HTTPException(status_code=500, detail="AI引擎未正确初始化")
    return request.app.state.ai_engine

class QueryRequest(BaseModel):
    bookId: str
    question: str
    position: int
    selectedText: Optional[str] = ""
    includeAfter: bool = False
    companionMode: bool = True

class CharacterDialogueRequest(BaseModel):
    bookId: str
    character: str
    userInput: str
    position: int

class StayAnalysisRequest(BaseModel):
    bookId: str
    stayRecords: Dict[int, float]  # position: duration

class ExternalDialogueRequest(BaseModel):
    content: str
    question: str

class InterestAnalysisRequest(BaseModel):
    bookId: str
    stayRecords: Dict[int, float]

class IngestRequest(BaseModel):
    bookId: str
    fileType: str

class MediaGenerationRequest(BaseModel):
    bookId: str
    chapterText: str
    chapterId: str

@router.post("/query")
async def query_with_context(
    request: QueryRequest,
    ai_engine = Depends(get_ai_engine)
):
    """根据选中文本、阅读位置和问题生成回答"""
    try:
        result = ai_engine.query_with_context(
            book_id=request.bookId,
            question=request.question,
            position=request.position,
            selected_text=request.selectedText,
            include_after=request.includeAfter,
            companion_mode=request.companionMode
        )
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"查询失败: {str(e)}")

@router.post("/ingest")
async def ingest_book(
    request: IngestRequest,
    ai_engine = Depends(get_ai_engine)
):
    """处理书籍，生成切片和嵌入索引"""
    try:
        result = ai_engine.ingest_book(request.bookId, request.fileType)
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"书籍处理失败: {str(e)}")

@router.post("/character-dialogue")
async def character_dialogue(
    request: CharacterDialogueRequest,
    ai_engine = Depends(get_ai_engine)
):
    """与书中人物对话，仅基于已读内容"""
    try:
        response = ai_engine.character_dialogue(
            book_id=request.bookId,
            character=request.character,
            user_input=request.userInput,
            position=request.position
        )
        return {"response": response}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"人物对话失败: {str(e)}")

@router.post("/analyze-stay-time")
async def analyze_stay_time(
    request: StayAnalysisRequest,
    ai_engine = Depends(get_ai_engine)
):
    """分析用户在书中停留时间最长的部分"""
    try:
        result = ai_engine.analyze_stay_time(request.bookId, request.stayRecords)
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"停留分析失败: {str(e)}")

@router.post("/external-dialogue")
async def external_dialogue(
    request: ExternalDialogueRequest,
    ai_engine = Depends(get_ai_engine)
):
    """基于导入内容的外部对话"""
    try:
        response = ai_engine.external_dialogue(request.content, request.question)
        return {"response": response}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"外部对话失败: {str(e)}")

@router.post("/analyze-interest")
async def analyze_interest(
    request: InterestAnalysisRequest,
    ai_engine = Depends(get_ai_engine)
):
    """根据停留记录分析用户兴趣并给出推荐"""
    try:
        recommendations = ai_engine.analyze_interest(request.bookId, request.stayRecords)
        return {"recommendations": recommendations}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"兴趣分析失败: {str(e)}")

@router.post("/generate-media")
async def generate_media(
    request: MediaGenerationRequest,
    ai_engine = Depends(get_ai_engine)
):
    """为章节生成音频和视频"""
    try:
        result = ai_engine.generate_chapter_media(
            book_id=request.bookId,
            chapter_text=request.chapterText,
            chapter_id=request.chapterId
        )
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"媒体生成失败: {str(e)}")

@router.get("/health")
async def health_check():
    """健康检查接口"""
    return {"status": "healthy", "service": "ai-router"}

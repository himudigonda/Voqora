class AIToolError(Exception):
    def __init__(self, message: str, *, status: int, code: str) -> None:
        super().__init__(message)
        self.user_message = message
        self.status = status
        self.code = code
